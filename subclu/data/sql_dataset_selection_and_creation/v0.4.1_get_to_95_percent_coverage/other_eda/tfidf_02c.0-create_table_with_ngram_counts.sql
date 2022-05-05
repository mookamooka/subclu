-- Create test table to count ngrams once and then reuse them as a separate step


DECLARE REGEX_REPLACE_CLEAN_MEDIA_LINKS STRING DEFAULT
    r"(\!\[)(\w{3,6})(\]\()(\w{6,}|[\w\s\|</>+;@#\?\!'_,.:\-]{7,80})(\s+\"[\w\s\|</>+;@#\?\!'_,{}\(\).:\-]+\"\s*|\s+'[\w\s\|</>+;@#\?\!\"_,{}\(\).:\-]+'\s*)?(\))";

DECLARE REGEX_STOPWORDS_TO_REMOVE STRING DEFAULT
    r"\bthe\b|\bto\b|\bde la\b|\bde\b|\best[oae]?s?n?y?\b|\bpara\b|\B:post-|\ba? ?las?|\bis it\b|\bis\b|\bdoes\b";

DECLARE REGEX_REMOVE STRING DEFAULT
    -- URL/UTM, contractions, S & M's from OCR, some punctuation
    r"(?i)\bi\.|https?:?//?|www\.?|&[a-z\\_]{2,}=[a-z\\_]+|\?[a-z\\_]{2,}=[a-z\\_]+|\.html?|\.com|\ss+\s+s+\b|\sm\s+s\b|\s+m\s+m\b|\b'\b|¿|…\B|—\B|\.gif|.jpe?g|\.org";

DECLARE REGEX_REPLACE_WITH_SPACE STRING DEFAULT
    r"(?i)/status/|&nbsp;|%[0-9a-f]{4}|%[0-9a-f]{2}|\n&#x200B;|%\w{2}|[”–·。;:%,\-=_\+\$\?\<\>’~#\\\/]+|\s?\| *:?-?:? *|&amp;|[\)!\('\.\"\]\[\*\{\}]+|\b\d+\b|”|」|\s&\s|\s@\s";


-- CREATE OR REPLACE TABLE `reddit-employee-datasets.david_bermejo.subreddit_ngram_test_20211215`
CREATE OR REPLACE TABLE `reddit-employee-datasets.david_bermejo.subreddit_text_test_20211215`
AS (
WITH
    preprocessed_text AS (
        -- Clean up the text before concat to prevent memory errors
        -- breaking it up doesn't work because we get errors with "cannot query rows larger than 100MB limit"
        SELECT
            p.subreddit_id
            , post_id
            -- Need to coalesce in case the regexes return an empty string
            , COALESCE(TRIM(
                  REGEXP_REPLACE(
                    REGEXP_REPLACE(
                        REGEXP_REPLACE(
                            REGEXP_REPLACE(
                                REGEXP_REPLACE(
                                    CONCAT(
                                        COALESCE(flair_text, '')
                                        , ' ', COALESCE(post_url_for_embeddings, '')
                                        , ' ', COALESCE(text, '')
                                        , ' ', COALESCE(ocr_inferred_text_agg_clean, '')
                                    ), REGEX_REPLACE_CLEAN_MEDIA_LINKS, r"\5 " -- keep only the description
                                ), REGEX_STOPWORDS_TO_REMOVE, ''
                            ), REGEX_REMOVE, ''
                        ), REGEX_REPLACE_WITH_SPACE, ' ' -- replace common items with space
                    ), r"\s{2,}|\n *\n *\n*|\n", " " -- remove extra spaces
                  )
            ), '.') AS clean_text

        FROM `reddit-employee-datasets.david_bermejo.subclu_posts_top_no_geo_20211214` AS p
            INNER JOIN `reddit-employee-datasets.david_bermejo.subclu_v0041_subreddit_clusters_c_a` AS sc
                ON p.subreddit_id = sc.subreddit_id
        WHERE 1=1
            -- filter by sub name
            AND p.subreddit_name IN (
                'formula1'
                , 'me_irl', 'china_irl'
                , 'newsg', 'ich_iel'
                , 'askreddit', 'fragreddit'
                , 'legaladvice', 'fatfire'
                , 'newparents', 'medicine'
                , 'netherlands', 'london'
                , 'lgbt'
                , 'cooking'
                , 'fuckcars', 'cars', 'cycling'
                , 'ucla', 'maliciouscompliance'
                , 'writing', 'relationship_advice', 'fitness'
                , 'wallstreetbets', 'ethereum'
                , 'foofighters', 'edm'
                , 'torontoraptors', 'baseball', 'nhl', 'nba', 'soccer', 'nfl', 'mma'
                , 'de', 'mexico', 'france', 'argentina', 'india', 'memexico'
                , 'explainlikeimfive', 'space', 'pics', 'economy'
                , 'worldnews', 'todayilearned'
                , 'skyrim', 'breath_of_the_wild', 'gaming', 'steam'
            )
            -- filter by label
            -- AND sc.k_0085_label IN (
            --     30, 40, 50
                -- ,  60, 70, 80, 84, 85
                -- , 11, 22, 33, 44, 55, 66, 77
                -- , 1, 2, 10, 20
            -- )
    )
    , ngram_per_subreddit_raw AS (
        -- how many times each word is mentioned in a cluster
        SELECT
            subreddit_id
            , TRIM(ngram) as ngram
            , count(1) AS ngram_count
        FROM preprocessed_text, UNNEST(
            ML.NGRAMS(
                SPLIT(
                    REGEXP_REPLACE(LOWER(TRIM(clean_text)), r'(\pP)', r" \1 ")
                    , ' '
                )
                , [1,3],  -- trigrams are about the limit
                ' '  -- character(s) to separate n-grams
            )
        ) as ngram
        WHERE ngram IS NOT NULL
            AND ngram NOT IN(
                '', ' ', ' ', '   ', '    ', '     '
                -- Common English tokens
                , 'the'
            )
        GROUP BY subreddit_id, TRIM(ngram)
    )
    , ngram_per_subreddit AS (
        SELECT
            *
            , (1 + array_length(regexp_extract_all(ngram, ' '))) AS ngram_type
            , CHAR_LENGTH(ngram) AS ngram_char_len
        FROM ngram_per_subreddit_raw
    )


-- Check clean text regexes
SELECT
    t.subreddit_name
    , t.flair_text
    , t.text
    , p.*
    , t.ocr_inferred_text_agg_clean
FROM preprocessed_text AS p
    LEFT JOIN `reddit-employee-datasets.david_bermejo.subclu_posts_top_no_geo_20211214` AS t
        ON p.post_id = t.post_id



-- Select n-grams for tf-idf & BM25
-- SELECT *
-- FROM ngram_per_subreddit
-- WHERE ngram_count >= 3

-- ORDER BY subreddit_id, ngram_count DESC

);  -- close CREATE table parens
