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
DROP TABLE IF EXISTS #wos_step1_score;
SELECT ntis_matching.ntis_id, wos.ut,
       CAST(NULL AS FLOAT) AS title, CAST(NULL AS FLOAT) AS source,
       --- Matching score of document titles and sources (Levenshtein distance)
       CAST(NULL AS FLOAT) AS year, CAST(NULL AS FLOAT) AS volume, CAST(NULL AS FLOAT) AS issue, CAST(NULL AS FLOAT) AS beginpage, CAST(NULL AS FLOAT) AS articleno,
       --- Matching score of each attribute
       CAST(NULL AS FLOAT) AS score
       --- Matching score (total)
  INTO #wos_step1_score
  FROM [userdb_eums].[dbo].[ntis_matching] AS ntis_matching
  INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
    ON ntis_matching.ntis_id = ntis_record.ntis_id
  INNER JOIN [wos_2513].[dbo].[pub] AS wos
    ON ntis_record.doi = wos.doi  
  WHERE ntis_matching.wos IS NULL; --- Unmatched NTIS records


--- 2. Score calculation: year, volume, issue, beginpage & articleno
UPDATE #wos_step1_score
  SET year = (CASE WHEN ntis_record.year = wos.pub_year THEN 1 WHEN ABS(ntis_record.year - wos.pub_year) = 1 THEN 0.5 WHEN ABS(ntis_record.year - wos.pub_year) = 2 THEN 0.25 ELSE 0 END),
      volume = (CASE WHEN ntis_record.volume = wos.volume THEN 1 ELSE 0 END),
	  issue = (CASE WHEN ntis_record.issue = wos.issue THEN 1 ELSE 0 END),
	  beginpage = (CASE WHEN ntis_record.beginpage = wos.page_begin THEN 1 ELSE 0 END),
	  articleno = (CASE WHEN ntis_record.articleno = wos.article_no THEN 1 ELSE 0 END)
  FROM #wos_step1_score AS ntis_score
  INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
    ON ntis_score.ntis_id = ntis_record.ntis_id
  INNER JOIN [wos_2513].[dbo].[pub] AS wos
    ON ntis_score.ut = wos.ut;


--- 3. Score calculation: title
WITH distance_title AS (
  SELECT ntis_score.ntis_id, ntis_score.ut,
         CAST(LEN(ntis_record.title) AS FLOAT) AS len_title_ntis, CAST(LEN(wos.title) AS FLOAT) AS len_title_wos,
		 --- Length of document titles to be compared
		 dbo.Levenshtein(ntis_record.title, wos.title) AS distance_title
		 --- Calculation of Levenshtein distance
    FROM #wos_step1_score AS ntis_score
	INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
	  ON ntis_score.ntis_id = ntis_record.ntis_id
	INNER JOIN [wos_2513].[dbo].[pub_detail] AS wos
	  ON ntis_score.ut = wos.ut)
UPDATE #wos_step1_score
  SET title = 1 - (distance_title / (CASE WHEN len_title_ntis >= len_title_wos THEN len_title_ntis ELSE len_title_wos END))
  FROM #wos_step1_score AS ntis_score
  INNER JOIN distance_title ON ntis_score.ntis_id = distance_title.ntis_id AND ntis_score.ut = distance_title.ut;


--- 4. Score calculation: source
--- 4.1 Comparing ISSNs (either p-ISSN or e-ISSN)
UPDATE #wos_step1_score
  SET source = 1
  FROM #wos_step1_score AS ntis_score
  INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
    ON ntis_score.ntis_id = ntis_record.ntis_id
  INNER JOIN [wos_2513].[dbo].[pub] AS wos
    ON ntis_score.ut = wos.ut
  INNER JOIN [wos_2513].[dbo].[source] AS wos_source
    ON wos.source_id = wos_source.source_id AND
	   (ntis_record.issn_e = wos_source.issn_e OR ntis_record.issn_p = wos_source.issn_print OR
	    ntis_record.issn_e = wos_source.issn_print OR ntis_record.issn_p = wos_source.issn_e);
		--- Cases where p-ISSN of one document matches e-ISSN of another document are also allowed

--- 4.2 Calculate similarity based on the LOWEST Levenshtein distance
DROP TABLE IF EXISTS #wos_step1_score_source;
SELECT ntis_score.ntis_id, ntis_score.ut,
       MAX(1 - ((dbo.Levenshtein(ntis_record.journal, Unpivoted.name) - ABS(LEN(ntis_record.journal) - LEN(Unpivoted.name))) /
	   NULLIF(CASE WHEN LEN(ntis_record.journal) <= LEN(Unpivoted.name) THEN LEN(ntis_record.journal) ELSE LEN(Unpivoted.name) END, 0))) AS min_distance
  INTO #wos_step1_score_source
  FROM #wos_step1_score AS ntis_score
  INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
    ON ntis_score.ntis_id = ntis_record.ntis_id
  INNER JOIN [wos_2513].[dbo].[pub] AS wos
    ON ntis_score.ut = wos.ut
  INNER JOIN [wos_2513].[dbo].[source] AS wos_source
    ON wos.source_id = wos_source.source_id
  INNER JOIN [wos_2513].[dbo].[pub_detail] AS wos_detail
    ON ntis_score.ut = wos_detail.ut
CROSS APPLY (
  SELECT wos_source.source_title AS name
  UNION
  SELECT wos_source.source_abbrev
  UNION 
  SELECT wos_source.source_abbrev_iso
  UNION
  SELECT wos_source.source_abbrev_11
  UNION
  SELECT wos_source.source_abbrev_29
  UNION
  SELECT wos_detail.source
  UNION
  SELECT wos_detail.source_abbr
) AS Unpivoted --- Variations in journal titles
  WHERE ntis_score.source IS NULL AND --- Do not calculate the distance if the score has already been assigned (by ISSNs)
        ntis_record.journal IS NOT NULL AND Unpivoted.name IS NOT NULL
  GROUP BY ntis_score.ntis_id, ntis_score.ut;

UPDATE #wos_step1_score
  SET source = score_source.min_distance
  FROM #wos_step1_score AS ntis_score
  INNER JOIN #wos_step1_score_source AS score_source
    ON ntis_score.ntis_id = score_source.ntis_id AND ntis_score.ut = score_source.ut;

	  
--- 5. Matching score calculation
UPDATE #wos_step1_score SET score = (40 * title) + (20 * source) + (10 * year) + (5 * volume) + (3 * issue) + (1 * beginpage) + (1 * articleno);


--- 6. Assessment of the matching score
WITH RankedRecords AS (
  SELECT ntis_id, RANK() OVER(PARTITION BY ntis_id ORDER BY score DESC) AS RankID FROM #wos_step1_score) --- Delete all but the highest matching score
DELETE FROM RankedRecords WHERE RankID > 1;

UPDATE [userdb_eums].[dbo].[ntis_matching]
  SET wos = ntis_score.ut
  FROM [userdb_eums].[dbo].[ntis_matching] AS ntis_matching
    INNER JOIN #wos_step1_score AS ntis_score
	  ON ntis_matching.ntis_id = ntis_score.ntis_id
  WHERE ntis_score.score >= 60;




-- =============================
--  Step 2. ISSN-based matching
-- =============================
--- 1. Table for pairs of all documents in WoS with the same ISSN and a publication year difference of within 2 years
DROP TABLE IF EXISTS #wos_step2_score;
SELECT ntis_matching.ntis_id, wos.ut,
       CAST(NULL AS FLOAT) AS title,
       --- Matching score of document titles (Levenshtein distance)
       CAST(NULL AS FLOAT) AS year, CAST(NULL AS FLOAT) AS volume, CAST(NULL AS FLOAT) AS issue, CAST(NULL AS FLOAT) AS beginpage, CAST(NULL AS FLOAT) AS articleno,
       --- Matching score of each attribute
       CAST(NULL AS FLOAT) AS score
       --- Matching score (total)
  INTO #wos_step2_score
  FROM [userdb_eums].[dbo].[ntis_matching] AS ntis_matching
  INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
    ON ntis_matching.ntis_id = ntis_record.ntis_id
  INNER JOIN [wos_2513].[dbo].[source] AS wos_source
    ON ntis_record.issn_p = wos_source.issn_print OR ntis_record.issn_e = wos_source.issn_e OR ntis_record.issn_p = wos_source.issn_e OR ntis_record.issn_e = wos_source.issn_print --- same ISSN
  INNER JOIN [wos_2513].[dbo].[pub] AS wos
    ON wos_source.source_id = wos.source_id AND (ABS(ntis_record.year - wos.pub_year) <= 2) --- publication year difference of within 2 years
  WHERE ntis_matching.wos IS NULL; --- Unmatched NTIS records


--- 2. Score calculation: year, volume, issue, beginpage & articleno
UPDATE #wos_step2_score
  SET year = (CASE WHEN ntis_record.year = wos.pub_year THEN 1 WHEN ABS(ntis_record.year - wos.pub_year) = 1 THEN 0.5 WHEN ABS(ntis_record.year - wos.pub_year) = 2 THEN 0.25 ELSE 0 END),
      volume = (CASE WHEN ntis_record.volume = wos.volume THEN 1 ELSE 0 END),
	  issue = (CASE WHEN ntis_record.issue = wos.issue THEN 1 ELSE 0 END),
	  beginpage = (CASE WHEN ntis_record.beginpage = wos.page_begin THEN 1 ELSE 0 END),
	  articleno = (CASE WHEN ntis_record.articleno = wos.article_no THEN 1 ELSE 0 END)
  FROM #wos_step2_score AS ntis_score
  INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
    ON ntis_score.ntis_id = ntis_record.ntis_id
  INNER JOIN [wos_2513].[dbo].[pub] AS wos
    ON ntis_score.ut = wos.ut;


--- 3. Score calculation: title
WITH distance_title AS (
  SELECT ntis_score.ntis_id, ntis_score.ut,
         CAST(LEN(ntis_record.title) AS FLOAT) AS len_title_ntis, CAST(LEN(wos.title) AS FLOAT) AS len_title_wos,
		 --- Length of document titles to be compared
		 dbo.Levenshtein(ntis_record.title, wos.title) AS distance_title
		 --- Calculation of Levenshtein distance
    FROM #wos_step2_score AS ntis_score
	INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
	  ON ntis_score.ntis_id = ntis_record.ntis_id
	INNER JOIN [wos_2513].[dbo].[pub_detail] AS wos
	  ON ntis_score.ut = wos.ut)
UPDATE #wos_step2_score
  SET title = 1 - (distance_title / (CASE WHEN len_title_ntis >= len_title_wos THEN len_title_ntis ELSE len_title_wos END))
  FROM #wos_step2_score AS ntis_score
  INNER JOIN distance_title ON ntis_score.ntis_id = distance_title.ntis_id AND ntis_score.ut = distance_title.ut;


--- 4. Matching score calculation
UPDATE #wos_step2_score SET score = (40 * title) + (18 * year) + (10 * volume) + (6 * issue) + (3 * beginpage) + (3 * articleno);


--- 5. Assessment of the matching score
WITH RankedRecords AS (
  SELECT ntis_id, RANK() OVER(PARTITION BY ntis_id ORDER BY score DESC) AS RankID FROM #wos_step2_score) --- Delete all but the highest matching score
DELETE FROM RankedRecords WHERE RankID > 1;

UPDATE [userdb_eums].[dbo].[ntis_matching]
  SET wos = ntis_score.ut
  FROM [userdb_eums].[dbo].[ntis_matching] AS ntis_matching
    INNER JOIN #wos_step2_score AS ntis_score
	  ON ntis_matching.ntis_id = ntis_score.ntis_id
  WHERE ntis_score.score >= 50;




-- ================================
--  Step 3. Journal-based matching
-- ================================
--- 1. Table for pairs of all documents in WoS with the same or similar journal name and a publication year difference of within 2 years
DROP TABLE IF EXISTS #wos_step3_score;
SELECT ntis_matching.ntis_id, wos.ut,
       CAST(NULL AS FLOAT) AS title,
       --- Matching score of document titles (Levenshtein distance)
       CAST(NULL AS FLOAT) AS year, CAST(NULL AS FLOAT) AS volume, CAST(NULL AS FLOAT) AS issue, CAST(NULL AS FLOAT) AS beginpage, CAST(NULL AS FLOAT) AS articleno,
       --- Matching score of each attribute
       CAST(NULL AS FLOAT) AS score
       --- Matching score (total)
  INTO #wos_step3_score
  FROM [userdb_eums].[dbo].[ntis_matching] AS ntis_matching
  INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
    ON ntis_matching.ntis_id = ntis_record.ntis_id
  INNER JOIN [wos_2513].[dbo].[pub] AS wos
    ON ABS(ntis_record.year - wos.pub_year) <= 2 --- publication year difference of within 2 years
  INNER JOIN [wos_2513].[dbo].[source] AS wos_source
    ON wos.source_id = wos_source.source_id
  LEFT JOIN [wos_2513].[dbo].[pub_detail] AS wos_pub_detail 
    ON wos.ut = wos_pub_detail.ut
  WHERE (ntis_record.journal IN (wos_source.source_title, wos_source.source_abbrev, wos_source.source_abbrev_iso, wos_source.source_abbrev_11, wos_source.source_abbrev_29) OR ntis_record.journal IN (wos_pub_detail.source, wos_pub_detail.source_abbr)) --- Variations in journal titles
        AND ntis_matching.wos IS NULL; --- Unmatched NTIS records


--- 2. Score calculation: year, volume, issue, beginpage & articleno
UPDATE #wos_step3_score
  SET year = (CASE WHEN ntis_record.year = wos.pub_year THEN 1 WHEN ABS(ntis_record.year - wos.pub_year) = 1 THEN 0.5 WHEN ABS(ntis_record.year - wos.pub_year) = 2 THEN 0.25 ELSE 0 END),
      volume = (CASE WHEN ntis_record.volume = wos.volume THEN 1 ELSE 0 END),
	  issue = (CASE WHEN ntis_record.issue = wos.issue THEN 1 ELSE 0 END),
	  beginpage = (CASE WHEN ntis_record.beginpage = wos.page_begin THEN 1 ELSE 0 END),
	  articleno = (CASE WHEN ntis_record.articleno = wos.article_no THEN 1 ELSE 0 END)
  FROM #wos_step3_score AS ntis_score
  INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
    ON ntis_score.ntis_id = ntis_record.ntis_id
  INNER JOIN [wos_2513].[dbo].[pub] AS wos
    ON ntis_score.ut = wos.ut;


--- 3. Score calculation: title
WITH distance_title AS (
  SELECT ntis_score.ntis_id, ntis_score.ut,
         CAST(LEN(ntis_record.title) AS FLOAT) AS len_title_ntis, CAST(LEN(wos.title) AS FLOAT) AS len_title_wos,
		 --- Length of document titles to be compared
		 dbo.Levenshtein(ntis_record.title, wos.title) AS distance_title
		 --- Calculation of Levenshtein distance
    FROM #wos_step3_score AS ntis_score
	INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
	  ON ntis_score.ntis_id = ntis_record.ntis_id
	INNER JOIN [wos_2513].[dbo].[pub_detail] AS wos
	  ON ntis_score.ut = wos.ut)
UPDATE #wos_step3_score
  SET title = 1 - (distance_title / (CASE WHEN len_title_ntis >= len_title_wos THEN len_title_ntis ELSE len_title_wos END))
  FROM #wos_step3_score AS ntis_score
  INNER JOIN distance_title ON ntis_score.ntis_id = distance_title.ntis_id AND ntis_score.ut = distance_title.ut;


--- 4. Matching score calculation
UPDATE #wos_step3_score SET score = (40 * title) + (14 * year) + (12 * volume) + (6 * issue) + (4 * beginpage) + (4 * articleno);


--- 5. Assessment of the matching score
WITH RankedRecords AS (
  SELECT ntis_id, RANK() OVER(PARTITION BY ntis_id ORDER BY score DESC) AS RankID FROM #wos_step3_score) --- Delete all but the highest matching score
DELETE FROM RankedRecords WHERE RankID > 1;

UPDATE [userdb_eums].[dbo].[ntis_matching]
  SET wos = ntis_score.ut
  FROM [userdb_eums].[dbo].[ntis_matching] AS ntis_matching
    INNER JOIN #wos_step3_score AS ntis_score
	  ON ntis_matching.ntis_id = ntis_score.ntis_id
  WHERE ntis_score.score >= 50;




-- ========================
--  Step 4. All match keys
-- ========================
--- 1. Recalculation of scores for unmatched records from tables in previous steps
--- 1.1 All candidate pairs
DROP TABLE IF EXISTS #wos_step4_score;
SELECT DISTINCT all_candidates.ntis_id, all_candidates.ut,
       all_candidates.title, all_candidates.source, all_candidates.year, all_candidates.volume, all_candidates.issue, all_candidates.beginpage, all_candidates.articleno,
	   CAST(NULL AS FLOAT) AS score
  INTO #wos_step4_score
  FROM (
    SELECT ntis_id, ut, title, source, year, volume, issue, beginpage, articleno FROM #wos_step1_score
    UNION
    SELECT ntis_id, ut, title, CAST(1 AS FLOAT), year, volume, issue, beginpage, articleno FROM #wos_step2_score
    UNION
    SELECT ntis_id, ut, title, CAST(1 AS FLOAT), year, volume, issue, beginpage, articleno FROM #wos_step3_score
	    ) AS all_candidates
  INNER JOIN [userdb_eums].[dbo].[ntis_matching] AS ntis_matching
    ON all_candidates.ntis_id = ntis_matching.ntis_id
WHERE ntis_matching.wos IS NULL;

--- 1.2 Score calculation
UPDATE #wos_step4_score SET score = (35 * title) + (25 * source) + (10 * year) + (5 * volume) + (3 * issue) + (1 * beginpage) + (1 * articleno);

--- 1.3 Assessment of the matching score
WITH RankedRecords AS (
  SELECT ntis_id, RANK() OVER(PARTITION BY ntis_id ORDER BY score DESC) AS RankID FROM #wos_step4_score) --- Delete all but the highest matching score
DELETE FROM RankedRecords WHERE RankID > 1;

UPDATE [userdb_eums].[dbo].[ntis_matching]
  SET wos = ntis_score.ut
  FROM [userdb_eums].[dbo].[ntis_matching] AS ntis_matching
    INNER JOIN #wos_step4_score AS ntis_score
	  ON ntis_matching.ntis_id = ntis_score.ntis_id
  WHERE ntis_score.score >= 60;


--- 2. DOIs of the corresponding documents of the records matched with OpenAlex
--- 2.1 WoS documents with the same DOI as the matched OpenAlex documents
DROP TABLE IF EXISTS #wos_step4_doi_score;
SELECT ntis_matching.ntis_id, wos.ut,
       CAST(NULL AS FLOAT) AS title, CAST(NULL AS FLOAT) AS source,
       --- Matching score of document titles and sources (Levenshtein distance)
       CAST(NULL AS FLOAT) AS year, CAST(NULL AS FLOAT) AS volume, CAST(NULL AS FLOAT) AS issue, CAST(NULL AS FLOAT) AS beginpage, CAST(NULL AS FLOAT) AS articleno,
       --- Matching score of each attribute
       CAST(NULL AS FLOAT) AS score
       --- Matching score (total)
  INTO #wos_step4_doi_score
  FROM [userdb_eums].[dbo].[ntis_matching] AS ntis_matching
  INNER JOIN [openalex_2025aug].[dbo].[work] AS openalex
    ON ntis_matching.openalex = openalex.work_id
  INNER JOIN [wos_2513].[dbo].[pub] AS wos
    ON openalex.doi = wos.doi
  WHERE ntis_matching.wos IS NULL; --- Unmatched NTIS records


--- 2.2 Score calculation: year, volume, issue, beginpage & articleno
UPDATE #wos_step4_doi_score
  SET year = (CASE WHEN ntis_record.year = wos.pub_year THEN 1 WHEN ABS(ntis_record.year - wos.pub_year) = 1 THEN 0.5 WHEN ABS(ntis_record.year - wos.pub_year) = 2 THEN 0.25 ELSE 0 END),
      volume = (CASE WHEN ntis_record.volume = wos.volume THEN 1 ELSE 0 END),
	  issue = (CASE WHEN ntis_record.issue = wos.issue THEN 1 ELSE 0 END),
	  beginpage = (CASE WHEN ntis_record.beginpage = wos.page_begin THEN 1 ELSE 0 END),
	  articleno = (CASE WHEN ntis_record.articleno = wos.article_no THEN 1 ELSE 0 END)
  FROM #wos_step4_doi_score AS ntis_score
  INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
    ON ntis_score.ntis_id = ntis_record.ntis_id
  INNER JOIN [wos_2513].[dbo].[pub] AS wos
    ON ntis_score.ut = wos.ut;


--- 2.3 Score calculation: title
WITH distance_title AS (
  SELECT ntis_score.ntis_id, ntis_score.ut,
         CAST(LEN(ntis_record.title) AS FLOAT) AS len_title_ntis, CAST(LEN(wos.title) AS FLOAT) AS len_title_wos,
		 --- Length of document titles to be compared
		 dbo.Levenshtein(ntis_record.title, wos.title) AS distance_title
		 --- Calculation of Levenshtein distance
    FROM #wos_step4_doi_score AS ntis_score
	INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
	  ON ntis_score.ntis_id = ntis_record.ntis_id
	INNER JOIN [wos_2513].[dbo].[pub_detail] AS wos
	  ON ntis_score.ut = wos.ut)
UPDATE #wos_step4_doi_score
  SET title = 1 - (distance_title / (CASE WHEN len_title_ntis >= len_title_wos THEN len_title_ntis ELSE len_title_wos END))
  FROM #wos_step4_doi_score AS ntis_score
  INNER JOIN distance_title ON ntis_score.ntis_id = distance_title.ntis_id AND ntis_score.ut = distance_title.ut;


--- 2.4 Score calculation: source
--- 2.4.1 Comparing ISSNs (either p-ISSN or e-ISSN)
UPDATE #wos_step4_doi_score
  SET source = 1
  FROM #wos_step4_doi_score AS ntis_score
  INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
    ON ntis_score.ntis_id = ntis_record.ntis_id
  INNER JOIN [wos_2513].[dbo].[pub] AS wos
    ON ntis_score.ut = wos.ut
  INNER JOIN [wos_2513].[dbo].[source] AS wos_source
    ON wos.source_id = wos_source.source_id AND
	   (ntis_record.issn_e = wos_source.issn_e OR ntis_record.issn_p = wos_source.issn_print OR
	    ntis_record.issn_e = wos_source.issn_print OR ntis_record.issn_p = wos_source.issn_e);
		--- Cases where p-ISSN of one document matches e-ISSN of another document are also allowed

--- 2.4.2 Calculate similarity based on the LOWEST Levenshtein distance
DROP TABLE IF EXISTS #wos_step4_doi_score_source;
SELECT ntis_score.ntis_id, ntis_score.ut,
       MAX(1 - ((dbo.Levenshtein(ntis_record.journal, Unpivoted.name) - ABS(LEN(ntis_record.journal) - LEN(Unpivoted.name))) /
	   NULLIF(CASE WHEN LEN(ntis_record.journal) <= LEN(Unpivoted.name) THEN LEN(ntis_record.journal) ELSE LEN(Unpivoted.name) END, 0))) AS min_distance
  INTO #wos_step4_doi_score_source
  FROM #wos_step4_doi_score AS ntis_score
  INNER JOIN [userdb_eums].[dbo].[ntis_record] AS ntis_record
    ON ntis_score.ntis_id = ntis_record.ntis_id
  INNER JOIN [wos_2513].[dbo].[pub] AS wos
    ON ntis_score.ut = wos.ut
  INNER JOIN [wos_2513].[dbo].[source] AS wos_source
    ON wos.source_id = wos_source.source_id
  INNER JOIN [wos_2513].[dbo].[pub_detail] AS wos_detail
    ON ntis_score.ut = wos_detail.ut
CROSS APPLY (
  SELECT wos_source.source_title AS name
  UNION
  SELECT wos_source.source_abbrev
  UNION 
  SELECT wos_source.source_abbrev_iso
  UNION
  SELECT wos_source.source_abbrev_11
  UNION
  SELECT wos_source.source_abbrev_29
  UNION
  SELECT wos_detail.source
  UNION
  SELECT wos_detail.source_abbr
) AS Unpivoted --- Variations in journal titles
  WHERE ntis_score.source IS NULL AND --- Do not calculate the distance if the score has already been assigned (by ISSNs)
        ntis_record.journal IS NOT NULL AND Unpivoted.name IS NOT NULL
  GROUP BY ntis_score.ntis_id, ntis_score.ut;

UPDATE #wos_step4_doi_score
  SET source = score_source.min_distance
  FROM #wos_step4_doi_score AS ntis_score
  INNER JOIN #wos_step4_doi_score_source AS score_source
    ON ntis_score.ntis_id = score_source.ntis_id AND ntis_score.ut = score_source.ut;

	  
--- 2.5 Matching score calculation
UPDATE #wos_step4_doi_score SET score = (35 * title) + (25 * source) + (10 * year) + (5 * volume) + (3 * issue) + (1 * beginpage) + (1 * articleno);


--- 2.6 Assessment of the matching score
WITH RankedRecords AS (
  SELECT ntis_id, RANK() OVER(PARTITION BY ntis_id ORDER BY score DESC) AS RankID FROM #wos_step4_doi_score) --- Delete all but the highest matching score
DELETE FROM RankedRecords WHERE RankID > 1;

UPDATE [userdb_eums].[dbo].[ntis_matching]
  SET wos = ntis_score.ut
  FROM [userdb_eums].[dbo].[ntis_matching] AS ntis_matching
    INNER JOIN #wos_step4_doi_score AS ntis_score
	  ON ntis_matching.ntis_id = ntis_score.ntis_id
  WHERE ntis_score.score >= 60;