-- =============================================================================================================
--  Description of table

--  [userdb_eums].[dbo].[ntis_matching] : Table of NTIS records and corresponding WoS and OpenAlex documents
--  Columns: ntis_id, wos, openalex

--  Attributes to be compared: DOI, first author, title, source, publication year, volume, issue, beginning page, and end page
--  For details on the calculation of the matching score, also see: Martijn Visser, Nees Jan van Eck, Ludo Waltman; Large-scale comparison of bibliographic data sources: Scopus, Web of Science, Dimensions, Crossref, and Microsoft Academic. Quantitative Science Studies 2021; 2 (1): 20–41. doi: https://doi.org/10.1162/qss_a_00112
-- =============================================================================================================

--- 1. Matched corresponding documents from WoS and OpenAlex
DROP TABLE IF EXISTS #wos_openalex_comparison_score;
SELECT ntis_id, wos AS ut, openalex AS work_id,
       CAST(NULL AS FLOAT) AS title, CAST(NULL AS FLOAT) AS source, CAST(NULL AS FLOAT) AS first_author,
       --- Matching score of document titles, sources, and first authors (Levenshtein distance)	   
       CAST(NULL AS FLOAT) AS doi, CAST(NULL AS FLOAT) AS year, CAST(NULL AS FLOAT) AS volume, CAST(NULL AS FLOAT) AS issue, CAST(NULL AS FLOAT) AS beginpage, CAST(NULL AS FLOAT) AS endpage,
       --- Matching score of each attribute
       CAST(NULL AS FLOAT) AS score
       --- Matching score (total)
  INTO #wos_openalex_comparison_score
  FROM [userdb_eums].[dbo].[ntis_matching]
  WHERE wos IS NOT NULL AND openalex IS NOT NULL;


--- 2. Score calculation: year, volume, issue, beginpage & endpage
UPDATE #wos_openalex_comparison_score
  SET year = (CASE WHEN openalex.pub_year = wos.pub_year THEN 1 ELSE 0 END),
      volume = (CASE WHEN openalex.volume = wos.volume THEN 1 ELSE 0 END),
	  issue = (CASE WHEN openalex.issue = wos.issue THEN 1 ELSE 0 END),
	  beginpage = (CASE WHEN openalex.page_first = wos.page_begin OR openalex.page_first = wos.article_no THEN 1 ELSE 0 END),
	  endpage = (CASE WHEN openalex.page_last = wos.page_end THEN 1 ELSE 0 END)
  FROM #wos_openalex_comparison_score AS comparison_score
  INNER JOIN [wos_2513].[dbo].[pub] AS wos
    ON comparison_score.ut = wos.ut
  INNER JOIN [openalex_2025aug].[dbo].[work] AS openalex
    ON comparison_score.work_id = openalex.work_id;


--- 3. Score calculation: title
WITH distance_title AS (
  SELECT comparison_score.ntis_id, comparison_score.ut, comparison_score.work_id,
         CAST(LEN(openalex.title) AS FLOAT) AS len_title_openalex, CAST(LEN(wos.title) AS FLOAT) AS len_title_wos,
		 --- Length of document titles to be compared
		 dbo.Levenshtein(openalex.title, wos.title) AS distance_title
		 --- Calculation of Levenshtein distance
    FROM #wos_openalex_comparison_score AS comparison_score
	INNER JOIN [openalex_2025aug].[dbo].[work_detail] AS openalex
	  ON comparison_score.work_id = openalex.work_id
	INNER JOIN [wos_2513].[dbo].[pub_detail] AS wos
	  ON comparison_score.ut = wos.ut)
UPDATE #wos_openalex_comparison_score
  SET title = 1 - (distance_title / (CASE WHEN len_title_openalex >= len_title_wos THEN len_title_openalex ELSE len_title_wos END))
  FROM #wos_openalex_comparison_score AS comparison_score
  INNER JOIN distance_title ON comparison_score.work_id = distance_title.work_id AND comparison_score.ut = distance_title.ut;


--- 4. Score calculation: source
--- 4.1 Unique pairs of [source_id] in WoS and OpenAlex
DROP TABLE IF EXISTS #wos_openalex_comparison_source;
SELECT DISTINCT wos.source_id AS source_wos, openalex.source_id AS source_openalex, CAST(NULL AS FLOAT) AS source_score
  INTO #wos_openalex_comparison_source
  FROM #wos_openalex_comparison_score AS comparison_score
  INNER JOIN [wos_2513].[dbo].[pub] AS wos ON comparison_score.ut = wos.ut
  INNER JOIN [openalex_2025aug].[dbo].[work] AS openalex ON comparison_score.work_id = openalex.work_id;

--- 4.2 Comparing ISSNs
UPDATE comparison_source
  SET source_score = 1
  FROM #wos_openalex_comparison_source AS comparison_source
  INNER JOIN [wos_2513].[dbo].[source] AS wos_source
    ON comparison_source.source_wos = wos_source.source_id  
  LEFT JOIN [openalex_2025aug].[dbo].[source] AS openalex_source
    ON comparison_source.source_openalex = openalex_source.source_id AND (wos_source.issn_e = openalex_source.issn_l OR wos_source.issn_print = openalex_source.issn_l)
  LEFT JOIN [openalex_2025aug].[dbo].[source_issn] AS openalex_source_issn
    ON comparison_source.source_openalex = openalex_source_issn.source_id AND (wos_source.issn_e = openalex_source_issn.issn OR wos_source.issn_print = openalex_source_issn.issn)
  WHERE openalex_source.source_id IS NOT NULL OR openalex_source_issn.source_id IS NOT NULL;

--- 4.3 Calculate similarity based on the LOWEST Levenshtein distance
DROP TABLE IF EXISTS #source_similarity;
SELECT c.source_wos, c.source_openalex,
       MAX(1 - ((dbo.Levenshtein(v_wos.name, v_oa.name) - ABS(LEN(v_wos.name) - LEN(v_oa.name))) / 
           NULLIF(CASE WHEN LEN(v_wos.name) <= LEN(v_oa.name) THEN LEN(v_wos.name) ELSE LEN(v_oa.name) END, 0))) AS max_sim
  INTO #source_similarity
  FROM #wos_openalex_comparison_source AS c
  INNER JOIN [wos_2513].[dbo].[source] AS wos_source ON c.source_wos = wos_source.source_id
  CROSS APPLY (
    SELECT wos_source.source_title AS name WHERE wos_source.source_title IS NOT NULL UNION
    SELECT wos_source.source_abbrev UNION SELECT wos_source.source_abbrev_iso UNION SELECT wos_source.source_abbrev_11 UNION SELECT wos_source.source_abbrev_29
  ) AS v_wos
  INNER JOIN [openalex_2025aug].[dbo].[source] AS openalex_source ON c.source_openalex = openalex_source.source_id
  CROSS APPLY (
    SELECT openalex_source.source AS name WHERE openalex_source.source IS NOT NULL UNION
    SELECT openalex_source.abbreviation UNION
    SELECT openalex_source_alt.alternative_title FROM [openalex_2025aug].[dbo].[source_alternative_title] AS openalex_source_alt WHERE openalex_source_alt.source_id = openalex_source.source_id
  ) AS v_oa
  WHERE c.source_score IS NULL
  GROUP BY c.source_wos, c.source_openalex;

UPDATE #wos_openalex_comparison_source
  SET source_score = b.max_sim
  FROM #wos_openalex_comparison_source AS a
  INNER JOIN #source_similarity AS b
    ON a.source_wos = b.source_wos AND a.source_openalex = b.source_openalex
  WHERE source_score IS NULL;

--- 4.4 Apply to WoS-OpenAlex document pairs
UPDATE #wos_openalex_comparison_score
  SET source = c.source_score
  FROM #wos_openalex_comparison_score AS comparison_score
  INNER JOIN [wos_2513].[dbo].[pub] AS wos
    ON comparison_score.ut = wos.ut
  INNER JOIN [openalex_2025aug].[dbo].[work] AS openalex
    ON comparison_score.work_id = openalex.work_id
  INNER JOIN #wos_openalex_comparison_source AS c
    ON wos.source_id = c.source_wos AND openalex.source_id = c.source_openalex;


--- 5. Score calculation: first author
--- 5.1 ORCID
UPDATE #wos_openalex_comparison_score
  SET first_author = 1
  FROM #wos_openalex_comparison_score AS comparison_score
  INNER JOIN [wos_2513].[dbo].[pub_author] AS wos_author
    ON comparison_score.ut = wos_author.ut AND wos_author.author_seq = 1
  INNER JOIN [openalex_2025aug].[dbo].[work_author] AS openalex_author
    ON comparison_score.work_id = openalex_author.work_id AND openalex_author.author_seq = 1
  INNER JOIN [openalex_2025aug].[dbo].[author] AS openalex_author_id
    ON openalex_author.author_id = openalex_author_id.author_id
  WHERE wos_author.orcid = openalex_author_id.orcid AND wos_author.orcid IS NOT NULL;

--- 5.2 Similarity
DROP TABLE IF EXISTS #wos_openalex_comparison_author;
SELECT c.ntis_id, c.ut, c.work_id,
       TRIM(LEFT(wos_author_name.author, CHARINDEX(',', wos_author_name.author + ',') - 1)) AS wos_ln, --- WoS Last Name
	   SUBSTRING(wos_author_name.author, NULLIF(CHARINDEX(', ', wos_author_name.author), 0) + 2, 1) AS wos_fi, --- WoS First Initial
	   TRIM(REVERSE(LEFT(REVERSE(openalex_author_name.author), CHARINDEX(' ', REVERSE(openalex_author_name.author) + ' ') - 1))) AS oa_ln, --- OpenAlex Last Name
	   LEFT(openalex_author_name.author, 1) AS oa_fi, --- OpenAlex First Initial
	   CAST(NULL AS FLOAT) AS score_first_author
  INTO #wos_openalex_comparison_author
  FROM #wos_openalex_comparison_score AS c
  INNER JOIN [wos_2513].[dbo].[pub_author] AS wos_author
    ON c.ut = wos_author.ut AND wos_author.author_seq = 1
  INNER JOIN [wos_2513].[dbo].[author] AS wos_author_name
    ON wos_author.author_id = wos_author_name.author_id
  INNER JOIN [openalex_2025aug].[dbo].[work_author] AS openalex_author
    ON c.work_id = openalex_author.work_id AND openalex_author.author_seq = 1
  INNER JOIN [openalex_2025aug].[dbo].[author] AS openalex_author_name
    ON openalex_author.author_id = openalex_author_name.author_id
  WHERE c.first_author IS NULL;

UPDATE #wos_openalex_comparison_author
  SET score_first_author = (0.8 * (1 - (dbo.Levenshtein(wos_ln, oa_ln) / NULLIF(CAST(CASE WHEN LEN(wos_ln) >= LEN(oa_ln) THEN LEN(wos_ln) ELSE LEN(oa_ln) END AS FLOAT), 0)))) + (0.2 * CASE WHEN wos_fi = oa_fi THEN 1 ELSE 0 END)
  WHERE wos_ln IS NOT NULL AND oa_ln IS NOT NULL;

UPDATE #wos_openalex_comparison_score
  SET first_author = b.score_first_author
  FROM #wos_openalex_comparison_score AS a
  INNER JOIN #wos_openalex_comparison_author AS b
    ON a.ntis_id = b.ntis_id AND a.ut = b.ut AND a.work_id = b.work_id;


--- 6. Matching score calculation
UPDATE #wos_openalex_comparison_score SET score = (15 * ISNULL(doi,0)) + (7 * ISNULL(first_author,0)) + (14 * ISNULL(title,0)) + (5 * ISNULL(source,0)) + (14 * ( (0.1 * year) + (0.2 * volume) + (0.1 * issue) + (0.3 * beginpage) + (0.3 * endpage) ));
--- If the score is 30 or higher, the matched documents from WoS and OpenAlex are determined to be identical