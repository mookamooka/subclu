-- Create new geo-relevant table that includes subreddits NOT active
--  Because many i18n-relevant subreddits will NOT be active (they're too small
--  to make it into the regular table).
-- Based on:
-- https://github.snooguts.net/reddit/data-science-airflow-etl/blob/master/dags/i18n/sql/geo_sfw_communities.sql

DECLARE active_pt_start DATE DEFAULT '2021-08-24';
DECLARE active_pt_end DATE DEFAULT '2021-09-07';
DECLARE regex_cleanup_country_name_str STRING DEFAULT r" of Great Britain and Northern Ireland| of America|";

-- Setting to 0.17 instead of 0.4 because some subreddits in LATAM
--  wouldn't show up as relevent b/c their country visits are split between too many countries
DECLARE min_pct_country NUMERIC DEFAULT 0.17;


CREATE OR REPLACE TABLE `reddit-employee-datasets.david_bermejo.subclu_geo_subreddits_20210909`
AS (

WITH
    -- Get count of all users for each subreddit
    tot_subreddit AS (
        SELECT
            -- pt,
            subreddit_name,
            SUM(l1) AS total_users
        FROM `data-prod-165221.all_reddit.all_reddit_subreddits_daily` arsub
        WHERE pt BETWEEN TIMESTAMP(active_pt_start) AND TIMESTAMP(active_pt_end)
        GROUP BY subreddit_name  --, pt
    ),

    -- Add count of users PER COUNTRY
    geo_sub AS (
        SELECT
            -- tot.pt
            tot.subreddit_name
            , arsub.geo_country_code
            , tot.total_users
            , SUM(l1) AS users_country

        FROM `data-prod-165221.all_reddit.all_reddit_subreddits_daily` arsub
        LEFT JOIN tot_subreddit tot ON
            tot.subreddit_name = arsub.subreddit_name
            -- AND tot.pt = arsub.pt
        WHERE arsub.pt BETWEEN TIMESTAMP(active_pt_start) AND TIMESTAMP(active_pt_end)
        GROUP BY tot.subreddit_name, arsub.geo_country_code, tot.total_users --, tot.pt
    ),

    -- Keep only subreddits+country above the percent threshold
    filtered_subreddits AS (
        SELECT DISTINCT
            -- pt
            geo_sub.subreddit_name
            , total_users
            , geo_country_code
            , SAFE_DIVIDE(users_country, total_users) AS users_percent_in_country
        FROM geo_sub
        WHERE SAFE_DIVIDE(users_country, total_users) >= min_pct_country
    ),

    -- Merge with subreddit_lookup for additional filters
    --  Add country names (instead of only codes)
    final_geo_output AS (
        SELECT
            CURRENT_DATE() AS pt
            , LOWER(s.name) AS subreddit_name
            , s.subreddit_id
            , r.geo_country_code
            , REGEXP_REPLACE(
                SPLIT(cm.country_name, ', ')[OFFSET(0)],
                regex_cleanup_country_name_str, ""
            ) AS country_name
            , cm.region AS geo_region
            , r.users_percent_in_country
            , r.total_users
            , active_pt_start   AS views_dt_start
            , active_pt_end     AS views_dt_end
            , over_18
            , verdict
            , type

        FROM filtered_subreddits r
        INNER JOIN (
            SELECT *
            FROM `data-prod-165221.ds_v2_postgres_tables.subreddit_lookup`
            WHERE dt = DATE(active_pt_end)
        ) AS s ON
            LOWER(r.subreddit_name) = LOWER(s.name)

        LEFT JOIN `data-prod-165221.ds_utility_tables.countrycode_region_mapping` AS cm
            ON r.geo_country_code = cm.country_code

        -- No longer using the active flag
        -- INNER JOIN `data-prod-165221.ds_subreddit_whitelist_tables.active_subreddits` a ON
        --     LOWER(r.subreddit_name) = LOWER(a.subreddit_name)

        WHERE 1=1
            AND COALESCE(verdict, 'f') <> 'admin_removed'
            AND COALESCE(is_spam, FALSE) = FALSE
            AND COALESCE(over_18, 'f') = 'f'
            AND COALESCE(is_deleted, FALSE) = FALSE
            AND deleted IS NULL
            AND type IN ('public', 'private', 'restricted')
            AND NOT REGEXP_CONTAINS(LOWER(s.name), r'^u_.*')
            -- AND a.active = TRUE

        ORDER BY total_users DESC, subreddit_name, users_percent_in_country DESC
    )

-- Select for table creation
SELECT *
FROM final_geo_output

)  -- close CREATE TABLE statement
;


-- ===========================
-- Tests/checks for query
-- ===
-- Check geo_sub
--   All subreddits appear here
-- SELECT
--     *
--     , (users_country / total_users)  AS users_percent_by_country
-- FROM geo_sub
-- WHERE 1=1
--     -- David's filter specific subs
--     AND LOWER(subreddit_name ) IN ('fussball', 'fifa_de', 'borussiadortmund')
-- ORDER BY subreddit_name, users_country DESC
-- ;


-- Check filtered subs
-- Expected: fifa_de & fussball
--      `borussiadortmund` gets dropped b/c no country is over 40%
-- Output: as expected :)
-- SELECT
--     *
-- FROM filtered_subreddits
-- WHERE 1=1
--     -- David's filter specific subs
--     AND LOWER(subreddit_name ) IN ('fussball', 'fifa_de', 'borussiadortmund', 'futbol')

-- ORDER BY subreddit_name, users_percent_by_country DESC
-- ;


-- Check final output
--  Expected: fifa_de, fussball
--  Output: fifa_de used to get drop b/c of old `active=true` filter
-- SELECT
--     *
-- FROM final_geo_output
-- WHERE 1=1
--     -- David's filter specific subs
--     -- AND LOWER(subreddit_name ) IN (
--     --     'fussball', 'fifa_de', 'borussiadortmund', 'futbol', 'soccer'
--     --     , 'dataisbeautiful'
--     --     )
--     AND geo_country_code NOT IN ("US", "GB")

-- LIMIT 10000
-- ;

-- Count subreddits per country
-- SELECT
--     geo_country_code
--     , country_name
--     , geo_region

--     , COUNT(DISTINCT subreddit_id) AS subreddit_unique_count

-- FROM final_geo_output
-- WHERE 1=1
--     AND total_users >= 1000

--     -- David's filter specific subs
--     -- AND LOWER(subreddit_name ) IN (
--     --     'fussball', 'fifa_de', 'borussiadortmund', 'futbol', 'soccer'
--     --     , 'dataisbeautiful'
--     --     )
--     -- AND geo_country_code NOT IN ("US", "GB")

-- GROUP BY 1, 2, 3

-- ORDER BY subreddit_unique_count DESC
-- ;
