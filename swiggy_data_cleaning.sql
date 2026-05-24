/* ============================================================================
   SWIGGY RESTAURANT DATA CLEANING & NORMALISATION  —  PostgreSQL
   ----------------------------------------------------------------------------
   Pipeline:  raw text staging  ->  typed & bucketed clean table  ->  cuisine
              bridge table (1NF)  ->  validation  ->  export.
   Dataset :  8,691 restaurants, 9 Indian metros, Swiggy partner snapshot
              (as of Jan 2022).
   ============================================================================ */


/* ---------------------------------------------------------------------------
   STAGE 1 — LOAD RAW (everything as text so the messy CSV imports cleanly)
   --------------------------------------------------------------------------- */
DROP TABLE IF EXISTS restaurants_raw;

CREATE TABLE restaurants_raw (
    type                  VARCHAR(10),
    id                    INTEGER,
    name                  VARCHAR(500),
    uuid                  VARCHAR(50),
    city                  VARCHAR(100),
    area                  VARCHAR(200),
    avg_rating            VARCHAR(50),
    total_ratings_string  VARCHAR(100),
    cuisines              VARCHAR(1000),
    cost_for_two_string   VARCHAR(100),
    delivery_time         INTEGER,
    min_delivery_time     INTEGER,
    max_delivery_time     INTEGER,
    address               VARCHAR(1000),
    locality              VARCHAR(200),
    unserviceable         BOOLEAN,
    veg                   BOOLEAN
);

COPY restaurants_raw
FROM '/path/to/Swiggy_dataset.csv'
WITH (FORMAT CSV, HEADER TRUE, ENCODING 'UTF8');     -- 8691 rows imported

-- Quick exploration
SELECT COUNT(*) FROM restaurants_raw;                              -- 8691
SELECT DISTINCT city FROM restaurants_raw;                         -- 9 cities
SELECT * FROM restaurants_raw LIMIT 10;
SELECT COUNT(*), COUNT(avg_rating), COUNT(cost_for_two_string)
FROM restaurants_raw;                                              -- completeness


/* ---------------------------------------------------------------------------
   STAGE 2 — CLEAN & CAST into restaurants_clean
   --------------------------------------------------------------------------- */
DROP TABLE IF EXISTS restaurants_clean;

CREATE TABLE restaurants_clean AS
SELECT
    id,
    name,
    city,
    TRIM(area)     AS area,
    TRIM(locality) AS locality,
    TRIM(address)  AS address,

    -- '--' placeholder -> NULL, else numeric rating
    CASE WHEN avg_rating = '--' THEN NULL
         ELSE avg_rating::NUMERIC(3,1) END                       AS avg_rating,
    CASE WHEN avg_rating = '--' THEN FALSE ELSE TRUE END         AS has_rating,

    -- strip '₹' and 'FOR TWO' -> integer cost
    CASE WHEN cost_for_two_string IS NULL OR cost_for_two_string = '' THEN NULL
         ELSE CAST(
              REGEXP_REPLACE(
                REGEXP_REPLACE(cost_for_two_string, '₹', ''),
                'FOR TWO', '') AS INTEGER) END                   AS cost_for_two,

    -- strip '+ ratings'; 'Too Few Ratings' -> NULL (floor count, hence _min)
    CASE WHEN total_ratings_string = 'Too Few Ratings' THEN NULL
         ELSE CAST(REGEXP_REPLACE(total_ratings_string,
                   '\+ ratings', '') AS INTEGER) END             AS ratings_count_min,

    -- keep raw cuisine array string; '[]' -> NULL
    CASE WHEN cuisines IS NULL OR cuisines = '[]' THEN NULL
         ELSE cuisines END                                        AS cuisines_raw,
    CASE WHEN cuisines IS NULL OR cuisines = '[]' THEN FALSE
         ELSE TRUE END                                            AS has_cuisine_data,

    delivery_time,
    veg,
    type
FROM restaurants_raw;                                             -- 8691 rows

-- Add business-tier buckets (filled below)
ALTER TABLE restaurants_clean ADD COLUMN rating_tier      VARCHAR(50);
ALTER TABLE restaurants_clean ADD COLUMN cost_tier        VARCHAR(50);
ALTER TABLE restaurants_clean ADD COLUMN delivery_speed   VARCHAR(50);
ALTER TABLE restaurants_clean ADD COLUMN ratings_bucket   VARCHAR(50);
ALTER TABLE restaurants_clean ADD COLUMN primary_cuisine  VARCHAR(200);
ALTER TABLE restaurants_clean ADD COLUMN cuisine_count    INTEGER;


/* ---------------------------------------------------------------------------
   STAGE 3 — CATEGORISE (continuous values -> reporting tiers)
   Order of WHEN matters: Postgres takes the first match.
   --------------------------------------------------------------------------- */
UPDATE restaurants_clean SET
    rating_tier = CASE
        WHEN avg_rating IS NULL THEN 'Unrated'
        WHEN avg_rating >= 4.3  THEN 'Excellent'
        WHEN avg_rating >= 4.0  THEN 'Good'
        WHEN avg_rating >= 3.5  THEN 'Average'
        ELSE 'Poor' END,

    cost_tier = CASE
        WHEN cost_for_two IS NULL  THEN 'Unknown'
        WHEN cost_for_two < 200    THEN 'Budget'
        WHEN cost_for_two < 400    THEN 'Affordable'
        WHEN cost_for_two < 700    THEN 'Mid-range'
        WHEN cost_for_two < 1200   THEN 'Premium'
        ELSE 'Luxury' END,

    delivery_speed = CASE
        WHEN delivery_time <= 20 THEN 'Very Fast'
        WHEN delivery_time <= 30 THEN 'Fast'
        WHEN delivery_time <= 45 THEN 'Average'
        WHEN delivery_time <= 60 THEN 'Slow'
        ELSE 'Very Slow' END,

    ratings_bucket = CASE
        WHEN ratings_count_min IS NULL    THEN 'Insufficient'
        WHEN ratings_count_min >= 10000   THEN '10K+'
        WHEN ratings_count_min >= 1000    THEN '1K-10K'
        WHEN ratings_count_min >= 500     THEN '500-1K'
        WHEN ratings_count_min >= 100     THEN '100-500'
        WHEN ratings_count_min >= 50      THEN '50-100'
        ELSE 'Under 50' END;


/* ---------------------------------------------------------------------------
   STAGE 4 — NORMALISE cuisines into a bridge table (1NF)
   --------------------------------------------------------------------------- */

-- ATTEMPT 1 (BROKEN): splitting on every space tears "North Indian" -> North, Indian
-- CREATE TABLE restaurant_cuisines AS
-- WITH cuisine_array AS (
--   SELECT id, STRING_TO_ARRAY(
--       TRIM(REPLACE(REPLACE(REPLACE(cuisines_raw,'[',''),']',''),'''','')), ' '
--   ) AS cuisines_list
--   FROM restaurants_clean WHERE has_cuisine_data = TRUE)
-- SELECT id AS restaurant_id, TRIM(cuisine) AS cuisine
-- FROM cuisine_array, LATERAL UNNEST(cuisines_list) AS cuisine
-- WHERE TRIM(cuisine) != '';

-- ATTEMPT 2 (CORRECT): split on quote-space-quote so multi-word names stay whole
DROP TABLE IF EXISTS restaurant_cuisines;

CREATE TABLE restaurant_cuisines AS
SELECT id AS restaurant_id,
       TRIM(BOTH '''' FROM cuisine) AS cuisine
FROM (
    SELECT id,
           REGEXP_SPLIT_TO_TABLE(
               SUBSTRING(cuisines_raw FROM 2 FOR LENGTH(cuisines_raw) - 2),  -- strip [ ]
               ''' '''                                                       -- split on ' '
           ) AS cuisine
    FROM restaurants_clean
    WHERE has_cuisine_data = TRUE
) AS exploded
WHERE TRIM(cuisine) != '';

-- Verify bridge table
SELECT COUNT(*)                  FROM restaurant_cuisines;   -- 23,652 relations
SELECT COUNT(DISTINCT cuisine)   FROM restaurant_cuisines;   -- 601 unique cuisines
SELECT COUNT(DISTINCT restaurant_id) FROM restaurant_cuisines; -- 8,691 restaurants

-- Top 10 cuisines
SELECT cuisine, COUNT(*) AS n
FROM restaurant_cuisines
GROUP BY cuisine ORDER BY n DESC LIMIT 10;


/* ---------------------------------------------------------------------------
   STAGE 5 — primary_cuisine + cuisine_count on the main table
   (cuisine_count sourced from the already-correct bridge table)
   --------------------------------------------------------------------------- */
UPDATE restaurants_clean SET
    primary_cuisine = CASE
        WHEN cuisines_raw IS NULL OR cuisines_raw = '[]' THEN NULL
        ELSE SUBSTRING(cuisines_raw
                FROM POSITION('''' IN cuisines_raw) + 1
                FOR  POSITION('''' IN SUBSTRING(cuisines_raw
                       FROM POSITION('''' IN cuisines_raw) + 1)) - 1)
        END,
    cuisine_count = (
        SELECT COUNT(*) FROM restaurant_cuisines rc
        WHERE rc.restaurant_id = restaurants_clean.id)
WHERE has_cuisine_data = TRUE;


/* ---------------------------------------------------------------------------
   STAGE 6 — VALIDATION & QUALITY CHECKS
   --------------------------------------------------------------------------- */
SELECT COUNT(*) AS total_restaurants FROM restaurants_clean;        -- 8,691
SELECT COUNT(DISTINCT city) AS cities FROM restaurants_clean;       -- 9

SELECT city, COUNT(*) AS n
FROM restaurants_clean GROUP BY city ORDER BY n DESC;

-- % unrated
SELECT ROUND(100.0 * (COUNT(*) - COUNT(avg_rating)) / COUNT(*), 1) AS pct_unrated
FROM restaurants_clean;                                            -- 37.7%

-- cost sanity
SELECT MIN(cost_for_two), MAX(cost_for_two), ROUND(AVG(cost_for_two)) AS avg_cost
FROM restaurants_clean;                                            -- 0 / 2500 / ~348

-- per-city scorecard (feeds the dashboard)
SELECT city,
       COUNT(*)                         AS restaurants,
       ROUND(AVG(avg_rating), 2)        AS avg_rating,
       ROUND(AVG(cost_for_two))         AS avg_cost,
       ROUND(AVG(delivery_time), 1)     AS avg_delivery_min
FROM restaurants_clean
GROUP BY city ORDER BY restaurants DESC;


/* ---------------------------------------------------------------------------
   STAGE 7 — EXPORT the two deliverables
   --------------------------------------------------------------------------- */
COPY restaurants_clean    TO '/path/to/restaurants_clean.csv'
     WITH (FORMAT CSV, HEADER TRUE, ENCODING 'UTF8');     -- 8,691 rows × 21 cols
COPY restaurant_cuisines  TO '/path/to/restaurant_cuisines.csv'
     WITH (FORMAT CSV, HEADER TRUE);                      -- 23,652 rows × 2 cols
