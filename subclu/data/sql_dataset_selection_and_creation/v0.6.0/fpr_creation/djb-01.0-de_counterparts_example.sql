-- Initial candidate list for subreddit counterpart FPR for a single country


-- Use this date to pull the latest partitions for QA, subreddit_lookup, etc.
DECLARE PT_DATE DATE DEFAULT CURRENT_DATE() - 2;

-- The query checks that the geo-relevant subreddit:
--  * Is geo-relevant to the target country
--  * Has the target language as one of the top 4 languages (rank<=4)
DECLARE GEO_TARGET_COUNTRY_CODE_TARGET STRING DEFAULT "DK";
DECLARE GEO_TARGET_LANGUAGE STRING DEFAULT "Danish";

-- Lower threshold  = add more subreddits, but they might be less relevant
-- Higher threshold = reduce relevant subreddits, but they're more local
--  Suggested range between: 2.5 and 3.0
-- For English-speaking countries increase even more: 4.0+
DECLARE STANDARDIZED_COUNTRY_THRESHOLD NUMERIC DEFAULT 2.5;

-- For non-English countries: ~0.25 is ok
-- For English-speaking countries: 0.3 or 0.4+
DECLARE MIN_PCT_USERS_L28_COUNTRY NUMERIC DEFAULT 0.2;

-- Min & max number of counterparts to show
DECLARE MIN_COUNTERPARTS_TO_SHOW NUMERIC DEFAULT 1;
DECLARE MAX_COUNTERPARTS_TO_SHOW NUMERIC DEFAULT 5;

-- Min US subscribers: Only show counterparts that have at least these many subscribers
--  Otherwise the impact will be too small, try 8k or 4k
DECLARE MIN_US_SUBSCRIBERS NUMERIC DEFAULT 4000;


-- Delete data from partition, if it exists
DELETE
    `reddit-employee-datasets.david_bermejo.fpr_counterparts`
WHERE
    pt = PT_DATE
    AND geo_country_code = GEO_TARGET_COUNTRY_CODE_TARGET
;

-- Create table (IF NOT EXISTS) | OR REPLACE
-- CREATE TABLE IF NOT EXISTS `reddit-employee-datasets.david_bermejo.fpr_counterparts`
-- PARTITION BY pt
-- AS (

-- Insert latest partition
INSERT INTO `reddit-employee-datasets.david_bermejo.fpr_counterparts`
(

WITH
    subs_relevant_baseline AS (
        -- Use this CTE to prevent recommending geo-relevant subs (example: DE to DE)
        SELECT
            ga.subreddit_id
        FROM `reddit-employee-datasets.david_bermejo.subclu_subreddit_relevance_beta_20220901` AS ga
        WHERE 1=1
            -- filters for geo-relevant country
            AND ga.geo_country_code = GEO_TARGET_COUNTRY_CODE_TARGET
            -- relevance filters
            AND (
                ga.users_percent_by_subreddit_l28 >= 0.20
            )
    ),

    subreddits_relevant_to_country AS (
        SELECT
            ga.geo_country_code
            , ga.subreddit_id
            , ga.subreddit_name
        FROM `reddit-employee-datasets.david_bermejo.subclu_subreddit_relevance_beta_20220901` AS ga
            -- Get primary language
            LEFT JOIN `reddit-employee-datasets.david_bermejo.subreddit_language_rank_20220808` AS lan
                ON ga.subreddit_id = lan.subreddit_id
            -- Use the new QA table to filter out subreddits that we shouldn't recommend
            LEFT JOIN `reddit-employee-datasets.david_bermejo.subreddit_qa_flags` AS q
                ON ga.subreddit_id = q.subreddit_id

        WHERE 1=1
            -- remove subreddits flagged as sensitive
            AND q.pt = PT_DATE
            AND q.combined_filter IN ('recommend', 'review')

            -- filters for geo-relevant country
            AND (
                ga.geo_country_code = GEO_TARGET_COUNTRY_CODE_TARGET
                -- relevance filters
                AND (
                    ga.users_percent_by_country_l28 >= MIN_PCT_USERS_L28_COUNTRY
                    OR ga.users_percent_by_country_standardized >= STANDARDIZED_COUNTRY_THRESHOLD
                )
                -- language filters
                AND (
                    lan.language_name = GEO_TARGET_LANGUAGE
                    AND lan.language_rank IN (1, 2, 3)
                    AND lan.thing_type = 'posts_and_comments'
                    AND lan.language_percent >= 0.05
                )
            )
    ),

    distance_lang_and_relevance_a AS (
        -- Select metadata for geo subs (sub_id_a) + get similarity
        SELECT
            ga.geo_country_code
            , subreddit_id_a AS subreddit_id_geo
            , subreddit_id_b AS subreddit_id_us

            , subreddit_name_a AS subreddit_name_geo
            , subreddit_name_b AS subreddit_name_us
            , cosine_similarity
            , slo.over_18 AS over_18_geo
            , slo.allow_discovery AS allow_discovery_geo
            , q.rating_short AS rating_short_geo
            , q.primary_topic AS primary_topic_geo

        FROM `reddit-employee-datasets.david_bermejo.subclu_v0050_subreddit_distances_c_top_100` AS d
            -- Get geo-relevance scores
            INNER JOIN subreddits_relevant_to_country AS ga
                ON d.subreddit_id_a = ga.subreddit_id
            LEFT JOIN subs_relevant_baseline AS gb
                ON d.subreddit_id_b = gb.subreddit_id
            LEFT JOIN (
                SELECT * FROM `data-prod-165221.ds_v2_postgres_tables.subreddit_lookup`
                WHERE dt = PT_DATE
            ) AS slo
                ON d.subreddit_id_a = slo.subreddit_id
            -- Get topic & rating from QA table because it includes CURATOR labels, not just crowd
            LEFT JOIN `reddit-employee-datasets.david_bermejo.subreddit_qa_flags` AS q
                ON ga.subreddit_id = q.subreddit_id
            LEFT JOIN `reddit-employee-datasets.david_bermejo.subreddits_no_recommendation` AS nr
                ON d.subreddit_name_b = nr.subreddit_name

        WHERE 1=1
            AND q.pt = PT_DATE
            -- Exclude subreddits that are geo-relevant to the country
            AND gb.subreddit_id IS NULL
            -- remove subreddits flagged as sensitive
            AND nr.subreddit_name IS NULL

            -- exclude subs with covid or corona in name
            AND subreddit_name_a NOT LIKE "%covid%"
            AND subreddit_name_a NOT LIKE "%coronavirus%"
            AND subreddit_name_b NOT LIKE "%covid%"
            AND subreddit_name_b NOT LIKE "%coronavirus%"
    ),
    distance_lang_and_relevance_a_and_b AS (
        -- Keep only counterpart subs that are in English, large by subscribers, & US-relevant
        SELECT
            a.* EXCEPT(
                -- language_name_geo, language_percent_geo, language_rank_geo,
                over_18_geo, rating_short_geo, primary_topic_geo, allow_discovery_geo
            )
            , slo.subscribers AS subscribers_us
            , ROW_NUMBER() OVER (PARTITION BY subreddit_id_GEO ORDER BY cosine_similarity DESC) AS rank_geo_to_us

            , allow_discovery_geo
            , rating_short_geo
            , q.rating_short AS rating_short_us
            , primary_topic_geo
            , primary_topic AS primary_topic_us

            -- , language_name_geo, language_percent_geo, language_rank_geo
            -- , lan.language_name AS primary_language_name_us
            -- , lan.language_percent AS primary_language_percent_us
            , over_18_geo
            , slo.over_18 AS over_18_us

        FROM distance_lang_and_relevance_a AS a
            LEFT JOIN `reddit-employee-datasets.david_bermejo.subclu_subreddit_relevance_beta_20220901` AS g
                ON a.subreddit_id_us = g.subreddit_id

            -- Get primary language
            LEFT JOIN `reddit-employee-datasets.david_bermejo.subreddit_language_rank_20220808` AS lan
                ON a.subreddit_id_us = lan.subreddit_id
            -- get subscribers
            LEFT JOIN `data-prod-165221.ds_v2_postgres_tables.subreddit_lookup` AS slo
                ON a.subreddit_id_us = slo.subreddit_id
            LEFT JOIN (
                SELECT * FROM `reddit-employee-datasets.david_bermejo.subreddit_qa_flags`
                WHERE pt = PT_DATE
            ) AS q
                ON a.subreddit_id_us = q.subreddit_id

        WHERE 1=1
            AND slo.dt = PT_DATE
            -- filters for US counterparts
            AND slo.subscribers >= MIN_US_SUBSCRIBERS
            AND q.combined_filter IN ('recommend', 'review')

            -- more filters for US counterparts
            AND (
                g.geo_country_code = 'US'
                -- relevance filters
                AND g.users_percent_by_subreddit_l28 >= 0.25
                -- language filters
                AND (
                    lan.language_name = 'English'
                    AND lan.language_rank = 1
                    AND lan.thing_type = 'posts_and_comments'
                    AND lan.language_percent >= 0.5
                )
            )
    )
    , counterparts_geo AS (
        -- Final check and filters to pick only expected number of counterparts per seed sub
        SELECT
            d.* EXCEPT(over_18_geo, over_18_us)
        FROM distance_lang_and_relevance_a_and_b AS d
        WHERE 1=1
            AND (
                rank_geo_to_us <= MIN_COUNTERPARTS_TO_SHOW
                OR cosine_similarity >= 0.77
            )
            AND rank_geo_to_us <= MAX_COUNTERPARTS_TO_SHOW
    )

-- final counterpart FPR with expected format
SELECT
    PT_DATE AS pt
    , geo_country_code
    , subreddit_id_geo AS subreddit_id
    , subreddit_name_geo AS subreddit_name

    , ARRAY_AGG(subreddit_id_us) AS subreddit_ids
    , ARRAY_AGG(subreddit_name_us) AS subreddit_names
FROM counterparts_geo
GROUP BY 1, 2, 3, 4
);
