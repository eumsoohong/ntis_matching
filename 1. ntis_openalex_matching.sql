-- =============================================================================================================
--  Description of tables

--  1. [userdb_eums].[dbo].[ntis_record] : Bibliographic information of NTIS records
--  Columns: ntis_id, doi, title, issn_p, issn_e, journal, year, volume, issue, beginpage, articleno

--  2. [userdb_eums].[dbo].[ntis_matching] : Table of NTIS records and corresponding WoS and OpenAlex documents
--  Columns: ntis_id, wos, openalex, matched
-- =============================================================================================================

-- ============================
--  Step 1. DOI-based matching
-- ============================
--- 1. Table for calculating the matching score for WoS documents having the same DOIs with NTIS records
DROP TABLE IF EXISTS #openalex_step1_score;
SELECT ntis_matching.ntis_id, openalex.work_id,
       CAST(NULL AS FLOAT) AS title, CAST(NULL AS FLOAT) AS source,
       --- Matching score of document titles and sources (Levenshtein distance)
       CAST(NULL AS FLOAT) AS year, CAST(NULL AS FLOAT) AS volume, CAST(NULL AS FLOAT) AS issue, CAST(NULL AS FLOAT) AS beginpage,
       --- Matching score of each attribute
       CAST(NULL AS FLOAT) AS score
       --- Matching score (total)
  INTO #openalex_step1_score
  FROM [userdb_eums].[dbo].[ntis_matching] AS ntis_matching
  INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
    ON ntis_matching.ntis_id = ntis_record.ntis_id
  INNER JOIN [openalex_2025aug].[dbo].[work] AS openalex
    ON ntis_record.doi = openalex.doi  
  WHERE ntis_matching.openalex IS NULL; --- Unmatched NTIS records


--- 2. Score calculation: year, volume, issue & beginpage
UPDATE #openalex_step1_score
  SET year = (CASE WHEN ntis_record.year = openalex.pub_year THEN 1 WHEN ABS(ntis_record.year - openalex.pub_year) = 1 THEN 0.5 WHEN ABS(ntis_record.year - openalex.pub_year) = 2 THEN 0.25 ELSE 0 END),
      volume = (CASE WHEN ntis_record.volume = openalex.volume THEN 1 ELSE 0 END),
	  issue = (CASE WHEN ntis_record.issue = openalex.issue THEN 1 ELSE 0 END),
	  beginpage = (CASE WHEN ntis_record.beginpage = openalex.page_first THEN 1 ELSE 0 END)
  FROM #openalex_step1_score AS ntis_score
  INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
    ON ntis_score.ntis_id = ntis_record.ntis_id
  INNER JOIN [openalex_2025aug].[dbo].[work] AS openalex
    ON ntis_score.work_id = openalex.work_id;


--- 3. Score calculation: title
WITH distance_title AS (
  SELECT ntis_score.ntis_id, ntis_score.work_id,
         CAST(LEN(ntis_record.title) AS FLOAT) AS len_title_ntis, CAST(LEN(openalex.title) AS FLOAT) AS len_title_wos,
		 --- Length of document titles to be compared
		 dbo.Levenshtein(ntis_record.title, openalex.title) AS distance_title
		 --- Calculation of Levenshtein distance
    FROM #openalex_step1_score AS ntis_score
	INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
	  ON ntis_score.ntis_id = ntis_record.ntis_id
	INNER JOIN [openalex_2025aug].[dbo].[work_detail] AS openalex
	  ON ntis_score.work_id = openalex.work_id)
UPDATE #openalex_step1_score
  SET title = 1 - (distance_title / (CASE WHEN len_title_ntis >= len_title_wos THEN len_title_ntis ELSE len_title_wos END))
  FROM #openalex_step1_score AS ntis_score
  INNER JOIN distance_title ON ntis_score.ntis_id = distance_title.ntis_id AND ntis_score.work_id = distance_title.work_id;


--- 4. Score calculation: source
--- 4.1 Comparing ISSNs
UPDATE #openalex_step1_score
  SET source = 1
  FROM #openalex_step1_score AS ntis_score
  INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
    ON ntis_score.ntis_id = ntis_record.ntis_id
  INNER JOIN [openalex_2025aug].[dbo].[work] AS openalex
    ON ntis_score.work_id = openalex.work_id
  LEFT JOIN [openalex_2025aug].[dbo].[source] AS src
    ON openalex.source_id = src.source_id AND (ntis_record.issn_e = src.issn_l OR ntis_record.issn_p = src.issn_l)
  LEFT JOIN [openalex_2025aug].[dbo].[source_issn] AS src_issn
    ON openalex.source_id = src_issn.source_id AND (ntis_record.issn_e = src_issn.issn OR ntis_record.issn_p = src_issn.issn)
  WHERE src.source_id IS NOT NULL OR src_issn.source_id IS NOT NULL;

--- 4.2 Calculate similarity based on the LOWEST Levenshtein distance
DROP TABLE IF EXISTS #openalex_step1_score_source;
SELECT ntis_score.ntis_id, ntis_score.work_id,
       MAX(1 - ((dbo.Levenshtein(ntis_record.journal, Unpivoted.source_name) - ABS(LEN(ntis_record.journal) - LEN(Unpivoted.source_name))) /
	   NULLIF(CASE WHEN LEN(ntis_record.journal) <= LEN(Unpivoted.source_name) THEN LEN(ntis_record.journal) ELSE LEN(Unpivoted.source_name) END, 0))) AS min_distance
  INTO #openalex_step1_score_source
  FROM #openalex_step1_score AS ntis_score
  INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record ON ntis_score.ntis_id = ntis_record.ntis_id
  INNER JOIN [openalex_2025aug].[dbo].[work] AS openalex ON ntis_score.work_id = openalex.work_id
  INNER JOIN [openalex_2025aug].[dbo].[source] AS openalex_source ON openalex.source_id = openalex_source.source_id
CROSS APPLY (
  SELECT openalex_source.source AS source_name WHERE openalex_source.source IS NOT NULL
  UNION
  SELECT openalex_source.abbreviation WHERE openalex_source.abbreviation IS NOT NULL
  UNION
  SELECT alt.alternative_title FROM [openalex_2025aug].[dbo].[source_alternative_title] AS alt WHERE alt.source_id = openalex.source_id
) AS Unpivoted --- Variations in journal titles
  WHERE ntis_score.source IS NULL AND ntis_record.journal IS NOT NULL
  GROUP BY ntis_score.ntis_id, ntis_score.work_id;

UPDATE #openalex_step1_score
  SET source = b.min_distance
  FROM #openalex_step1_score AS s
  INNER JOIN #openalex_step1_score_source AS b
    ON s.ntis_id = b.ntis_id AND s.work_id = b.work_id;

	  
--- 5. Matching score calculation
UPDATE #openalex_step1_score SET score = (40 * title) + (20 * source) + (10 * year) + (5 * volume) + (3 * issue) + (2 * beginpage);


--- 6. Assessment of the matching score
WITH RankedRecords AS (
  SELECT ntis_id, RANK() OVER(PARTITION BY ntis_id ORDER BY score DESC) AS RankID FROM #openalex_step1_score) --- Delete all but the highest matching score
DELETE FROM RankedRecords WHERE RankID > 1;

UPDATE [userdb_eums].[dbo].[ntis_matching]
  SET openalex = ntis_score.work_id
  FROM [userdb_eums].[dbo].[ntis_matching] AS ntis_matching
    INNER JOIN #openalex_step1_score AS ntis_score
	  ON ntis_matching.ntis_id = ntis_score.ntis_id
  WHERE ntis_score.score >= 60;




-- =============================
--  Step 2. ISSN-based matching
-- =============================
--- 1. Table for pairs of all documents in OpenAlex with the same ISSN and a publication year difference of within 2 years
DROP TABLE IF EXISTS #openalex_step2_score;
SELECT ntis_matching.ntis_id, openalex.work_id,
       CAST(NULL AS FLOAT) AS title,
       --- Matching score of document titles and sources (Levenshtein distance)
       CAST(NULL AS FLOAT) AS year, CAST(NULL AS FLOAT) AS volume, CAST(NULL AS FLOAT) AS issue, CAST(NULL AS FLOAT) AS beginpage,
       --- Matching score of each attribute
       CAST(NULL AS FLOAT) AS score
       --- Matching score (total)
  INTO #openalex_step2_score
  FROM [userdb_eums].[dbo].[ntis_matching] AS ntis_matching
  INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
    ON ntis_matching.ntis_id = ntis_record.ntis_id
  INNER JOIN [openalex_2025aug].[dbo].[work] AS openalex
    ON ABS(ntis_record.year - openalex.pub_year) <= 2 --- publication year difference of within 2 years
  LEFT JOIN [openalex_2025aug].[dbo].[source] AS openalex_source
    ON openalex.source_id = openalex_source.source_id AND (ntis_record.issn_p = openalex_source.issn_l OR ntis_record.issn_e = openalex_source.issn_l)
  LEFT JOIN [openalex_2025aug].[dbo].[source_issn] AS openalex_source_issn
    ON openalex.source_id = openalex_source_issn.source_id AND (ntis_record.issn_p = openalex_source_issn.issn OR ntis_record.issn_e = openalex_source_issn.issn)
  WHERE (openalex_source.source_id IS NOT NULL OR openalex_source_issn.source_id IS NOT NULL) AND
        ntis_matching.openalex IS NULL; --- Unmatched NTIS records


-- 2. Score calculation: year, volume, issue & beginpage
UPDATE #openalex_step2_score
  SET year = (CASE WHEN ntis_record.year = openalex.pub_year THEN 1 WHEN ABS(ntis_record.year - openalex.pub_year) = 1 THEN 0.5 WHEN ABS(ntis_record.year - openalex.pub_year) = 2 THEN 0.25 ELSE 0 END),
      volume = (CASE WHEN ntis_record.volume = openalex.volume THEN 1 ELSE 0 END),
	  issue = (CASE WHEN ntis_record.issue = openalex.issue THEN 1 ELSE 0 END),
	  beginpage = (CASE WHEN ntis_record.beginpage = openalex.page_first THEN 1 ELSE 0 END)
  FROM #openalex_step2_score AS ntis_score
  INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
    ON ntis_score.ntis_id = ntis_record.ntis_id
  INNER JOIN [openalex_2025aug].[dbo].[work] AS openalex
    ON ntis_score.work_id = openalex.work_id;


--- 3. Score calculation: title
WITH distance_title AS (
  SELECT ntis_score.ntis_id, ntis_score.work_id,
         CAST(LEN(ntis_record.title) AS FLOAT) AS len_title_ntis, CAST(LEN(openalex.title) AS FLOAT) AS len_title_wos,
		 --- Length of document titles to be compared
		 dbo.Levenshtein(ntis_record.title, openalex.title) AS distance_title
		 --- Calculation of Levenshtein distance
    FROM #openalex_step2_score AS ntis_score
	INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
	  ON ntis_score.ntis_id = ntis_record.ntis_id
	INNER JOIN [openalex_2025aug].[dbo].[work_detail] AS openalex
	  ON ntis_score.work_id = openalex.work_id)
UPDATE #openalex_step2_score
  SET title = 1 - (distance_title / (CASE WHEN len_title_ntis >= len_title_wos THEN len_title_ntis ELSE len_title_wos END))
  FROM #openalex_step2_score AS ntis_score
  INNER JOIN distance_title ON ntis_score.ntis_id = distance_title.ntis_id AND ntis_score.work_id = distance_title.work_id;


--- 4. Matching score calculation
UPDATE #openalex_step2_score SET score = (40 * title) + (18 * year) + (10 * volume) + (7 * issue) + (5 * beginpage);


--- 5. Assessment of the matching score
WITH RankedRecords AS (
  SELECT ntis_id, RANK() OVER(PARTITION BY ntis_id ORDER BY score DESC) AS RankID FROM #openalex_step2_score) --- Delete all but the highest matching score
DELETE FROM RankedRecords WHERE RankID > 1;

UPDATE [userdb_eums].[dbo].[ntis_matching]
  SET openalex = ntis_score.work_id
  FROM [userdb_eums].[dbo].[ntis_matching] AS ntis_matching
    INNER JOIN #openalex_step2_score AS ntis_score
	  ON ntis_matching.ntis_id = ntis_score.ntis_id
  WHERE ntis_score.score >= 50;




-- ================================
--  Step 3. Journal-based matching
-- ================================
--- 1. Table for pairs of all documents in OpenAlex with the same or similar journal name and a publication year difference of within 2 years
DROP TABLE IF EXISTS #openalex_step3_score;
SELECT ntis_matching.ntis_id, openalex.work_id,
       CAST(NULL AS FLOAT) AS title,
       --- Matching score of document titles and sources (Levenshtein distance)
       CAST(NULL AS FLOAT) AS year, CAST(NULL AS FLOAT) AS volume, CAST(NULL AS FLOAT) AS issue, CAST(NULL AS FLOAT) AS beginpage,
       --- Matching score of each attribute
       CAST(NULL AS FLOAT) AS score
       --- Matching score (total)
  INTO #openalex_step3_score
  FROM [userdb_eums].[dbo].[ntis_matching] AS ntis_matching
  INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
    ON ntis_matching.ntis_id = ntis_record.ntis_id
  INNER JOIN [openalex_2025aug].[dbo].[work] AS openalex
    ON ABS(ntis_record.year - openalex.pub_year) <= 2 --- publication year difference of within 2 years
  INNER JOIN [openalex_2025aug].[dbo].[source] AS openalex_source
    ON openalex.source_id = openalex_source.source_id
  LEFT JOIN [openalex_2025aug].[dbo].[source_alternative_title] AS openalex_source_alternative_title
    ON openalex.source_id = openalex_source_alternative_title.source_id
  WHERE (ntis_record.journal = openalex_source.source OR ntis_record.journal = openalex_source_alternative_title.alternative_title) --- Variations in journal titles
  AND ntis_matching.openalex IS NULL; --- Unmatched NTIS records


-- 2. Score calculation: year, volume, issue & beginpage
UPDATE #openalex_step3_score
  SET year = (CASE WHEN ntis_record.year = openalex.pub_year THEN 1 WHEN ABS(ntis_record.year - openalex.pub_year) = 1 THEN 0.5 WHEN ABS(ntis_record.year - openalex.pub_year) = 2 THEN 0.25 ELSE 0 END),
      volume = (CASE WHEN ntis_record.volume = openalex.volume THEN 1 ELSE 0 END),
	  issue = (CASE WHEN ntis_record.issue = openalex.issue THEN 1 ELSE 0 END),
	  beginpage = (CASE WHEN ntis_record.beginpage = openalex.page_first THEN 1 ELSE 0 END)
  FROM #openalex_step3_score AS ntis_score
  INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
    ON ntis_score.ntis_id = ntis_record.ntis_id
  INNER JOIN [openalex_2025aug].[dbo].[work] AS openalex
    ON ntis_score.work_id = openalex.work_id;


--- 3. Score calculation: title
WITH distance_title AS (
  SELECT ntis_score.ntis_id, ntis_score.work_id,
         CAST(LEN(ntis_record.title) AS FLOAT) AS len_title_ntis, CAST(LEN(openalex.title) AS FLOAT) AS len_title_wos,
		 --- Length of document titles to be compared
		 dbo.Levenshtein(ntis_record.title, openalex.title) AS distance_title
		 --- Calculation of Levenshtein distance
    FROM #openalex_step3_score AS ntis_score
	INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
	  ON ntis_score.ntis_id = ntis_record.ntis_id
	INNER JOIN [openalex_2025aug].[dbo].[work_detail] AS openalex
	  ON ntis_score.work_id = openalex.work_id)
UPDATE #openalex_step3_score
  SET title = 1 - (distance_title / (CASE WHEN len_title_ntis >= len_title_wos THEN len_title_ntis ELSE len_title_wos END))
  FROM #openalex_step3_score AS ntis_score
  INNER JOIN distance_title ON ntis_score.ntis_id = distance_title.ntis_id AND ntis_score.work_id = distance_title.work_id;


--- 4. Matching score calculation
UPDATE #openalex_step3_score SET score = (40 * title) + (14 * year) + (12 * volume) + (8 * issue) + (6 * beginpage);


--- 5. Assessment of the matching score
WITH RankedRecords AS (
  SELECT ntis_id, RANK() OVER(PARTITION BY ntis_id ORDER BY score DESC) AS RankID FROM #openalex_step3_score) --- Delete all but the highest matching score
DELETE FROM RankedRecords WHERE RankID > 1;

UPDATE [userdb_eums].[dbo].[ntis_matching]
  SET openalex = ntis_score.work_id
  FROM [userdb_eums].[dbo].[ntis_matching] AS ntis_matching
    INNER JOIN #openalex_step3_score AS ntis_score
	  ON ntis_matching.ntis_id = ntis_score.ntis_id
  WHERE ntis_score.score >= 50;




-- ========================
--  Step 4. All match keys
-- ========================
--- 1. Recalculation of scores for unmatched records from tables in previous steps
--- 1.1 All candidate pairs
DROP TABLE IF EXISTS #openalex_step4_score;
SELECT DISTINCT all_candidates.ntis_id, all_candidates.work_id,
       all_candidates.title, all_candidates.source, all_candidates.year, all_candidates.volume, all_candidates.issue, all_candidates.beginpage,
	   CAST(NULL AS FLOAT) AS score
  INTO #openalex_step4_score
  FROM (
    SELECT ntis_id, work_id, title, source, year, volume, issue, beginpage FROM #openalex_step1_score
    UNION
    SELECT ntis_id, work_id, title, CAST(1 AS FLOAT), year, volume, issue, beginpage FROM #openalex_step2_score
    UNION
    SELECT ntis_id, work_id, title, CAST(1 AS FLOAT), year, volume, issue, beginpage FROM #openalex_step3_score) AS all_candidates
  INNER JOIN [userdb_eums].[dbo].[ntis_matching] AS ntis_matching
    ON all_candidates.ntis_id = ntis_matching.ntis_id
WHERE ntis_matching.openalex IS NULL;

--- 1.2 Score calculation
UPDATE #openalex_step1_score SET score = (35 * title) + (25 * source) + (10 * year) + (5 * volume) + (3 * issue) + (2 * beginpage);

--- 1.3 Assessment of the matching score
WITH RankedRecords AS (
  SELECT ntis_id, RANK() OVER(PARTITION BY ntis_id ORDER BY score DESC) AS RankID FROM #openalex_step4_score) --- Delete all but the highest matching score
DELETE FROM RankedRecords WHERE RankID > 1;

UPDATE [userdb_eums].[dbo].[ntis_matching]
  SET openalex = ntis_score.work_id
  FROM [userdb_eums].[dbo].[ntis_matching] AS ntis_matching
    INNER JOIN #openalex_step4_score AS ntis_score
	  ON ntis_matching.ntis_id = ntis_score.ntis_id
  WHERE ntis_score.score >= 60;


--- 2. DOIs of the corresponding documents of the records matched with WoS
--- 2.1 OpenAlex documents with the same DOI as the matched WoS documents
DROP TABLE IF EXISTS #openalex_step1_score;
SELECT ntis_matching.ntis_id, openalex.work_id,
       CAST(NULL AS FLOAT) AS title, CAST(NULL AS FLOAT) AS source,
       --- Matching score of document titles and sources (Levenshtein distance)
       CAST(NULL AS FLOAT) AS year, CAST(NULL AS FLOAT) AS volume, CAST(NULL AS FLOAT) AS issue, CAST(NULL AS FLOAT) AS beginpage,
       --- Matching score of each attribute
       CAST(NULL AS FLOAT) AS score
       --- Matching score (total)
  INTO #openalex_step1_score
  FROM [userdb_eums].[dbo].[ntis_matching] AS ntis_matching
  INNER JOIN [wos_2513].[dbo].[pub] AS wos
    ON ntis_matching.wos = wos.ut
  INNER JOIN [openalex_2025aug].[dbo].[work] AS openalex
    ON wos.doi = openalex.doi
  WHERE ntis_matching.openalex IS NULL; --- Unmatched NTIS records


--- 2.2 Score calculation: year, volume, issue & beginpage
UPDATE #openalex_step4_doi_score
  SET year = (CASE WHEN ntis_record.year = openalex.pub_year THEN 1 WHEN ABS(ntis_record.year - openalex.pub_year) = 1 THEN 0.5 WHEN ABS(ntis_record.year - openalex.pub_year) = 2 THEN 0.25 ELSE 0 END),
      volume = (CASE WHEN ntis_record.volume = openalex.volume THEN 1 ELSE 0 END),
	  issue = (CASE WHEN ntis_record.issue = openalex.issue THEN 1 ELSE 0 END),
	  beginpage = (CASE WHEN ntis_record.beginpage = openalex.page_first THEN 1 ELSE 0 END)
  FROM #openalex_step4_doi_score AS ntis_score
  INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
    ON ntis_score.ntis_id = ntis_record.ntis_id
  INNER JOIN [openalex_2025aug].[dbo].[work] AS openalex
    ON ntis_score.work_id = openalex.work_id;


--- 2.3 Score calculation: title
WITH distance_title AS (
  SELECT ntis_score.ntis_id, ntis_score.work_id,
         CAST(LEN(ntis_record.title) AS FLOAT) AS len_title_ntis, CAST(LEN(openalex.title) AS FLOAT) AS len_title_wos,
		 --- Length of document titles to be compared
		 dbo.Levenshtein(ntis_record.title, openalex.title) AS distance_title
		 --- Calculation of Levenshtein distance
    FROM #openalex_step4_doi_score AS ntis_score
	INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
	  ON ntis_score.ntis_id = ntis_record.ntis_id
	INNER JOIN [openalex_2025aug].[dbo].[work_detail] AS openalex
	  ON ntis_score.work_id = openalex.work_id)
UPDATE #openalex_step4_doi_score
  SET title = 1 - (distance_title / (CASE WHEN len_title_ntis >= len_title_wos THEN len_title_ntis ELSE len_title_wos END))
  FROM #openalex_step4_doi_score AS ntis_score
  INNER JOIN distance_title ON ntis_score.ntis_id = distance_title.ntis_id AND ntis_score.work_id = distance_title.work_id;


--- 2.4 Score calculation: source
--- 2.4.1 Comparing ISSNs
UPDATE #openalex_step4_doi_score
  SET source = 1
  FROM #openalex_step4_doi_score AS ntis_score
  INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
    ON ntis_score.ntis_id = ntis_record.ntis_id
  INNER JOIN [openalex_2025aug].[dbo].[work] AS openalex
    ON ntis_score.work_id = openalex.work_id
  LEFT JOIN [openalex_2025aug].[dbo].[source] AS src
    ON openalex.source_id = src.source_id AND (ntis_record.issn_e = src.issn_l OR ntis_record.issn_p = src.issn_l)
  LEFT JOIN [openalex_2025aug].[dbo].[source_issn] AS src_issn
    ON openalex.source_id = src_issn.source_id AND (ntis_record.issn_e = src_issn.issn OR ntis_record.issn_p = src_issn.issn)
  WHERE src.source_id IS NOT NULL OR src_issn.source_id IS NOT NULL;

--- 2.4.2 Calculate similarity based on the LOWEST Levenshtein distance
DROP TABLE IF EXISTS #openalex_step4_doi_score_source;
SELECT ntis_score.ntis_id, ntis_score.work_id,
       MAX(1 - ((dbo.Levenshtein(ntis_record.journal, Unpivoted.source_name) - ABS(LEN(ntis_record.journal) - LEN(Unpivoted.source_name))) /
	   NULLIF(CASE WHEN LEN(ntis_record.journal) <= LEN(Unpivoted.source_name) THEN LEN(ntis_record.journal) ELSE LEN(Unpivoted.source_name) END, 0))) AS min_distance
  INTO #openalex_step4_doi_score_source
  FROM #openalex_step4_doi_score AS ntis_score
  INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record ON ntis_score.ntis_id = ntis_record.ntis_id
  INNER JOIN [openalex_2025aug].[dbo].[work] AS openalex ON ntis_score.work_id = openalex.work_id
  INNER JOIN [openalex_2025aug].[dbo].[source] AS openalex_source ON openalex.source_id = openalex_source.source_id
CROSS APPLY (
  SELECT openalex_source.source AS source_name WHERE openalex_source.source IS NOT NULL
  UNION
  SELECT openalex_source.abbreviation WHERE openalex_source.abbreviation IS NOT NULL
  UNION
  SELECT alt.alternative_title FROM [openalex_2025aug].[dbo].[source_alternative_title] AS alt WHERE alt.source_id = openalex.source_id
) AS Unpivoted --- Variations in journal titles
  WHERE ntis_score.source IS NULL AND ntis_record.journal IS NOT NULL
  GROUP BY ntis_score.ntis_id, ntis_score.work_id;

UPDATE #openalex_step4_doi_score
  SET source = b.min_distance
  FROM #openalex_step4_doi_score AS s
  INNER JOIN #openalex_step4_doi_score_source AS b
    ON s.ntis_id = b.ntis_id AND s.work_id = b.work_id;

	  
--- 2.5 Matching score calculation
UPDATE #openalex_step4_doi_score SET score = (35 * title) + (25 * source) + (10 * year) + (5 * volume) + (3 * issue) + (2 * beginpage);


--- 2.6 Assessment of the matching score
WITH RankedRecords AS (
  SELECT ntis_id, RANK() OVER(PARTITION BY ntis_id ORDER BY score DESC) AS RankID FROM #openalex_step4_doi_score) --- Delete all but the highest matching score
DELETE FROM RankedRecords WHERE RankID > 1;

UPDATE [userdb_eums].[dbo].[ntis_matching]
  SET openalex = ntis_score.work_id
  FROM [userdb_eums].[dbo].[ntis_matching] AS ntis_matching
    INNER JOIN #openalex_step4_doi_score AS ntis_score
	  ON ntis_matching.ntis_id = ntis_score.ntis_id
  WHERE ntis_score.score >= 60;