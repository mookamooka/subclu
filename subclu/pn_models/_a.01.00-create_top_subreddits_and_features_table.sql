-- A. Select top subreddits as targets for PNs
--   ETA: 15 seconds
DECLARE PARTITION_DATE DATE DEFAULT '2023-05-06';

DECLARE MIN_USERS_L7_ENGLISH NUMERIC DEFAULT 300;
DECLARE MIN_USERS_L7_ROW NUMERIC DEFAULT 150;

DECLARE MIN_POSTS_L7_ENGLISH NUMERIC DEFAULT 3;
DECLARE MIN_POSTS_L7_ROW_NO_RATING NUMERIC DEFAULT 6;
DECLARE MIN_POSTS_L7_ROW_W_RATING NUMERIC DEFAULT 1;

DECLARE TARGET_GEOS_ENG DEFAULT [
    "US", "CA"
];
DECLARE TARGET_GEOS_ROW DEFAULT [
    "IN", "IE", "AU", "GB"
    , "MX", "ES", "AR"
    , "DE", "AT", "CH"
    , "FR", "NL", "IT"
    , "BR", "PT"
    , "PH"
];


-- ==================
-- Only need to create the first time we run it
-- === OR REPLACE
-- CREATE TABLE `reddit-employee-datasets.david_bermejo.pn_ft_subreddits_20230509`
-- PARTITION BY pt
-- AS (

-- ==================
-- After table is created, we can delete a partition & update it
-- ===
DELETE
    `reddit-employee-datasets.david_bermejo.pn_ft_subreddits_20230509`
WHERE
    pt = PARTITION_DATE
;

-- Insert latest data
INSERT INTO `reddit-employee-datasets.david_bermejo.pn_ft_subreddits_20230509`
(

WITH
subs_above_thresholds AS (
    SELECT
        slo.subreddit_id
        , asr.subreddit_name
        , slo.over_18
        , tx.curator_rating
        , tx.curator_topic_v2
        , asr.* EXCEPT(subreddit_name)
    FROM (
        SELECT
            subreddit_name
            , posts_l7
            , posts_l28
            , LN(1 + posts_l7) AS posts_log_l7
            , LN(1 + posts_l28) AS posts_log_l28

            , users_l7
            , users_l14
            , users_l28
            , LN(1 + users_l7) AS users_log_l7
            , LN(1 + users_l14) AS users_log_l14
            , LN(1 + users_l28) AS users_log_l28

            , comments_l7
            , comments_l28
            , LN(1 + comments_l7) AS comments_log_l7
            , LN(1 + comments_l28) AS comments_log_l28

            , seo_users_l28
            , SAFE_DIVIDE(seo_users_l28, users_l28) AS seo_users_pct_l28
            , loggedin_users_l28
            , SAFE_DIVIDE(loggedin_users_l28, users_l28) AS loggedin_users_pct_l28
            , ios_users_l28
            , SAFE_DIVIDE(ios_users_l28, users_l28) AS ios_users_pct_l28
            , android_users_l28
            , SAFE_DIVIDE(android_users_l28, users_l28) AS android_users_pct_l28

            , votes_l7
            , votes_l28
            , LN(1 + votes_l7) AS votes_log_l7
            , LN(1 + votes_l28) AS votes_log_l28

        FROM `data-prod-165221.all_reddit.all_reddit_subreddits`
        WHERE DATE(pt) = PARTITION_DATE
            AND users_l7 >= LEAST(MIN_USERS_L7_ENGLISH, MIN_USERS_L7_ROW)
            AND posts_l7 >= LEAST(MIN_POSTS_L7_ENGLISH, MIN_POSTS_L7_ROW_W_RATING)
            AND NOT REGEXP_CONTAINS(LOWER(subreddit_name), r'^u_.*')
    ) AS asr
        -- Get subreddit-id & exclude banned subreddits
        INNER JOIN (
            SELECT name, subreddit_id, over_18
            FROM `data-prod-165221.ds_v2_postgres_tables.subreddit_lookup`
            WHERE dt = PARTITION_DATE
                -- Exclude user-profiles + spam & sketchy subs [optional]
                AND COALESCE(verdict, 'f') <> 'admin-removed'
                AND COALESCE(is_spam, FALSE) = FALSE
                AND COALESCE(is_deleted, FALSE) = FALSE
                AND deleted IS NULL
                AND type IN ('public', 'private', 'restricted')
                AND NOT REGEXP_CONTAINS(LOWER(name), r'^u_.*')
        ) AS slo
            ON asr.subreddit_name = LOWER(slo.name)

        -- Get ratings
        LEFT JOIN `data-prod-165221.taxonomy.daily_export` AS tx
            ON slo.subreddit_id = tx.subreddit_id
    WHERE 1=1
        AND NOT (
            -- exclude ALL subs about trauma & support, independent of rating, like r/selfharmscars, r/rape
            COALESCE(tx.curator_topic_v2, "") IN (
                'Trauma Support', 'Addiction Support', 'Illegal & Recreational Drugs'
            )
        )
        AND NOT (
            (
                -- exclude subs over-18 dedicated to celebrities (usually porn/fetish)
                COALESCE(tx.curator_topic_v2, "") IN ("Celebrities")
                -- exclude over-18 and unrated
                OR tx.curator_rating IS NULL
            )
            AND COALESCE(over_18, '') = 't'
        )
        AND (
            -- We can keep the unrated subs here because we filtered out the combinations where unrated is riskier
            COALESCE(tx.curator_rating, "") IN ('Everyone', "Mature 1", "")
        )
)
, subs_with_geo_long AS (
    -- Get geo data for subs & apply filters based on country group
    SELECT
        sel.subreddit_id
        , cl.geo_country_code
        , cl.sub_dau_perc_l28
        , cl.perc_by_country_sd
        , cl.localness

    FROM (
        SELECT
            -- We need distinct b/c there can be duplicates in the community-local-scores table :((
            DISTINCT
            subreddit_id
            , geo_country_code
            , sub_dau_perc_l28
            , perc_by_country_sd
            , localness
        FROM `data-prod-165221.i18n.community_local_scores`
        WHERE DATE(pt) = PARTITION_DATE
            -- Start with only target countries & somewhat local subs
            AND geo_country_code IN UNNEST(ARRAY_CONCAT(TARGET_GEOS_ENG, TARGET_GEOS_ROW))
            AND localness != 'not_local'

    ) AS cl
        LEFT JOIN subs_above_thresholds AS sel
            ON cl.subreddit_id = sel.subreddit_id

    WHERE sel.subreddit_id IS NOT NULL

        AND (
            -- Apply Eng filters
            (
                cl.geo_country_code IN UNNEST(TARGET_GEOS_ENG)
                AND cl.localness IN ('strict', 'loose')
                AND sel.posts_l7 >= MIN_POSTS_L7_ENGLISH
                AND sel.users_l7 >= MIN_USERS_L7_ENGLISH
                AND sel.curator_rating IS NOT NULL
            )

            -- Apply RoW filters
            OR (
                cl.geo_country_code IN UNNEST(TARGET_GEOS_ROW)
                AND cl.localness IN ('strict', 'loose')
                AND sel.users_l7 >= MIN_USERS_L7_ROW
                AND (
                    -- Rated subs get a lower min of posts
                    (
                        sel.posts_l7 >= MIN_POSTS_L7_ROW_W_RATING
                        AND sel.curator_rating IS NOT NULL
                    )
                    -- Unrated subs get a higher minimum of posts
                    OR (
                        sel.posts_l7 >= MIN_POSTS_L7_ROW_NO_RATING
                        AND sel.curator_rating IS NULL
                    )
                )
            )
        )
)
, subs_with_geo_wide AS (
    SELECT
        subreddit_id

        , STRING_AGG(geo_country_code, ', ' ORDER BY geo_country_code) AS relevant_geo_country_codes
        , COUNT(DISTINCT geo_country_code) AS relevant_geo_country_code_count
    FROM subs_with_geo_long
    GROUP BY 1
)
, selected_subs_with_meta AS (
    SELECT
        sm.* EXCEPT(subreddit_id)
        , sa.*
    FROM subs_above_thresholds AS sa
        INNER JOIN subs_with_geo_wide AS sm
            ON sa.subreddit_id = sm.subreddit_id
)

-- Final select for table CREATE/INSERT
SELECT
  PARTITION_DATE AS pt
  , *
FROM selected_subs_with_meta
);  -- Close CREATE/INSERT parens


-- ============
-- Test CTEs
-- ===

-- Check the baseline subreddits
--  Note: we expect to filter more of these because we'll only allow unrated for ROW countries
--    (exclude unrated subreddits when they're only relevant to large English-speaking countries)
-- SELECT *
-- FROM subs_above_thresholds
-- ORDER BY over_18 DESC, curator_rating, curator_topic_v2, users_l7 DESC, posts_l7 DESC
-- ;


-- Check sub<>geo CTE
-- SELECT *
-- FROM subs_with_geo
-- WHERE 1=1
--     -- AND geo_country_code IN (
--     --     'MX'
--     --     , 'US'
--     -- )
-- ORDER BY geo_country_code, posts_l7 DESC, users_l7 DESC, curator_rating, curator_topic_v2
-- ;
