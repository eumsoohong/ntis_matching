-- =========================================================================================================================
--  Description of table

--  1. [userdb_eums].[dbo].[ntis_matching] : Table of NTIS records and corresponding WoS and OpenAlex documents
--  Columns: ntis_id, wos, openalex, matched

--- 2. #ntis_source_link : Master table of linked journals in WoS and OpenAlex
--  Columns: source_id_wos, source_id_openalex

--  3. #ntis_paper_kr_fund_wos : Korean-Funded publications (WoS)
--  Columns: ut, funding_seq, cwts_organization_id, full_name, organization_type, in_ntis, matched_journal

--  4. #ntis_paper_kr_fund_openalex : Korean-Funded publications (OpenAlex)
--  Columns: work_id, grant_seq, funder_id, funder, organization_type, in_ntis, matched_journal

--  5. #ntis_paper_kr_fund_connect : Unique pairs of Korean-funded publications from WoS (#ntis_paper_kr_fund_wos) and OpenAlex (#ntis_paper_kr_fund_openalex)
--  Columns: ut, work_id

--  6. #ntis_paper_kr_fund_wos_fundertype : Korean-funded publications with added funder information (WoS)
--  Columns: ut, funding_seq, cwts_organization_id, full_name, organization_type, organization_type_code, in_ntis, criteria

--  7. #ntis_paper_kr_fund_openalex_fundertype : Korean-funded publications with added funder information (OpenAlex)
--  Columns: work_id, grant_seq, funder_id, funder, organization_type, organization_type_id, in_ntis, criteria
-- =========================================================================================================================


-- ===========================================================================================
--  1. Control of the journals in which the coverage of funded publications is to be compared
-- ===========================================================================================
--- 1. [source_id] from WoS & OpenAlex
--- 1.1 WoS Sources
DROP TABLE IF EXISTS #wos_sources;
SELECT DISTINCT s.source_id, v.val AS link_val, 'ISSN' AS link_type
  INTO #wos_sources
  FROM [wos_2513].[dbo].[source] AS s
  CROSS APPLY (VALUES (s.issn_print), (s.issn_e), (UPPER(REPLACE(s.source_title, ' ', '')))) v(val)
  WHERE s.source_id IN (SELECT DISTINCT b.source_id
                          FROM [userdb_eums].[dbo].[ntis_matching] AS a
						  INNER JOIN [wos_2513].[dbo].[pub] AS b ON a.wos = b.ut)
    AND v.val IS NOT NULL;

--- 1.2 OpenAlex Sources
DROP TABLE IF EXISTS #openalex_sources;
  SELECT DISTINCT s.source_id, v.val AS link_val
  INTO #openalex_sources
  FROM [openalex_2025aug].[dbo].[source] AS s
  LEFT JOIN [openalex_2025aug].[dbo].[source_issn] AS si ON s.source_id = si.source_id
  LEFT JOIN [openalex_2025aug].[dbo].[source_alternative_title] AS alt ON s.source_id = alt.source_id
  CROSS APPLY (VALUES (s.issn_l), (si.issn), (UPPER(REPLACE(s.source, ' ', ''))), (UPPER(REPLACE(alt.alternative_title, ' ', '')))) v(val)
  WHERE s.source_id IN (SELECT DISTINCT b.source_id
                          FROM [userdb_eums].[dbo].[ntis_matching] AS a
						  INNER JOIN [openalex_2025aug].[dbo].[work] AS b ON a.openalex = b.work_id)
    AND v.val IS NOT NULL;


--- 2. Link [source_id] between WoS & OpenAlex
--- 2.1 Matched pairs of [source_id]
DROP TABLE IF EXISTS #ntis_source_link;
SELECT DISTINCT w.source_id AS source_id_wos, o.source_id AS source_id_openalex
  INTO #ntis_source_link
  FROM #wos_sources AS w
  INNER JOIN #openalex_sources AS o ON w.link_val = o.link_val;

--- 2.2 Add remaining unlinked sources
INSERT INTO #ntis_source_link (source_id_wos)
SELECT DISTINCT source_id FROM #wos_sources
  WHERE source_id NOT IN (SELECT source_id_wos FROM #ntis_source_link WHERE source_id_wos IS NOT NULL);

INSERT INTO #ntis_source_link (source_id_openalex)
SELECT DISTINCT source_id FROM #openalex_sources
  WHERE source_id NOT IN (SELECT source_id_openalex FROM #ntis_source_link WHERE source_id_openalex IS NOT NULL);



-- ====================================================
--  2. Korean-funded publications (journal controlled)
-- ====================================================
--- 1. Korean-Funded publications (WoS)
DROP TABLE IF EXISTS #ntis_paper_kr_fund_wos;
SELECT DISTINCT p.ut, f.funding_seq, f.cwts_organization_id, org.full_name, ot.organization_type,
                CAST(IIF(m.wos IS NOT NULL, 1, 0) AS BIT) AS in_ntis,
				CAST(IIF(sl.source_id_openalex IS NOT NULL, 1, 0) AS BIT) AS matched_journal
  INTO #ntis_paper_kr_fund_wos
  FROM #ntis_source_link AS sl
  INNER JOIN [wos_2513].[dbo].[pub] AS p ON sl.source_id_wos = p.source_id
  INNER JOIN [wos_2513_organization_funding].[dbo].[pub_funding_main_organization] AS f ON p.ut = f.ut
  INNER JOIN [wos_2513_organization_funding].[dbo].[organization] AS org ON f.cwts_organization_id = org.cwts_organization_id
  INNER JOIN [wos_2513_organization_funding].[dbo].[organization_organization_type] AS otl ON f.cwts_organization_id = otl.cwts_organization_id
  INNER JOIN [wos_2513_organization_funding].[dbo].[organization_type] AS ot ON otl.organization_type_code = ot.organization_type_code
  LEFT JOIN [userdb_eums].[dbo].[ntis_matching] AS m ON p.ut = m.wos
  WHERE org.country_iso_num_code = 410;


--- 2. Korean-Funded publications (OpenAlex)
DROP TABLE IF EXISTS #ntis_paper_kr_fund_openalex;
SELECT DISTINCT w.work_id, g.grant_seq, f.funder_id, f.funder, ot.organization_type,
                CAST(IIF(m.openalex IS NOT NULL, 1, 0) AS BIT) AS in_ntis,
				CAST(IIF(sl.source_id_wos IS NOT NULL, 1, 0) AS BIT) AS matched_journal
  INTO #ntis_paper_kr_fund_openalex
  FROM #ntis_source_link sl
  INNER JOIN [openalex_2025aug].[dbo].[work] AS w ON sl.source_id_openalex = w.source_id
  INNER JOIN [openalex_2025aug].[dbo].[work_grant] AS g ON w.work_id = g.work_id
  INNER JOIN [openalex_2025aug].[dbo].[funder] AS f ON g.funder_id = f.funder_id
  INNER JOIN [ror_2025feb].[dbo].[organization_organization_type] AS otl ON f.ror_id = otl.ror_id
  INNER JOIN [ror_2025feb].[dbo].[organization_type] AS ot ON otl.organization_type_id = ot.organization_type_id
  LEFT JOIN [userdb_eums].[dbo].[ntis_matching] AS m ON w.work_id = m.openalex
  WHERE f.country_iso_alpha2_code = 'KR';


--- 3. Linking documents between NTIS, WoS and OpenAlex
DROP TABLE IF EXISTS #ntis_paper_kr_fund_connect;
SELECT DISTINCT a.ut, d.work_id
  INTO #ntis_paper_kr_fund_connect
  FROM #ntis_paper_kr_fund_wos AS a
  INNER JOIN [wos_2513].[dbo].[pub] AS b ON a.ut = b.ut
  INNER JOIN [openalex_2025aug].[dbo].[work] AS c ON b.doi = c.doi --- Same DOI
  INNER JOIN #ntis_paper_kr_fund_openalex AS d ON c.work_id = d.work_id;



-- =======================================================
--  3. Korean-funded publications with funder information
-- =======================================================
--- 1. WoS
--- Loose criteria : Funding Organisation (FO), Governmental Institution (G), Research organisation (R), University (U)
--- Strict criteria: Funding Organisation (FO), Governmental Institution (G)
DROP TABLE IF EXISTS #ntis_paper_kr_fund_wos_fundertype;
SELECT ut, funding_seq, cwts_organization_id, full_name, organization_type, organization_type_code, in_ntis,
       CASE WHEN organization_type_code IN ('FO', 'G') THEN 'strict' ELSE 'loose' END AS criteria
  INTO #ntis_paper_kr_fund_wos_fundertype
  FROM #ntis_paper_kr_fund_wos
  WHERE matched_journal = 1 AND organization_type_code IN ('FO', 'G', 'R', 'U');
--- Note: More than one organization_type may be assigned to the same cwts_organization_id

--- 2. OpenAlex
--- Loose criteria : Education (3), Facility (4), Government (5), funder (9)
--- Strict criteria: Government (5), funder (9)
DROP TABLE IF EXISTS #ntis_paper_kr_fund_openalex_fundertype;
SELECT work_id, grant_seq, funder_id, funder, organization_type, organization_type_id, in_ntis,
       CASE WHEN organization_type_id IN ('5', '9') THEN 'strict' ELSE 'loose' END AS criteria
  INTO #ntis_paper_kr_fund_openalex_fundertype
  FROM #ntis_paper_kr_fund_openalex
  WHERE matched_journal = 1 AND organization_type_id IN ('3', '4', '5', '9');
--- Note: More than one organization_type may be assigned to the same funder_id



-- ==========================================================
--  4. Counting Korean-funded publications (strict criteria)
-- ==========================================================
--- 1. Korean-funded publications in NTIS, WoS & OpenAlex
--- 1.1 NTIS
SELECT COUNT(*) FROM (SELECT DISTINCT wos, openalex FROM [userdb_eums].[dbo].[ntis_matching]) AS sub;

--- 1.2 WoS
SELECT COUNT(DISTINCT a.ut) FROM #ntis_paper_kr_fund_wos AS a
  INNER JOIN #ntis_paper_kr_fund_wos_fundertype AS b ON a.ut = b.ut
  WHERE b.criteria = 'strict'; --- This row is not applied for loose criteria

--- 1.3 OpenAlex
SELECT COUNT(DISTINCT work_id) FROM #ntis_paper_kr_fund_openalex AS a
  INNER JOIN #ntis_paper_kr_fund_openalex_fundertype AS b ON a.work_id = b.work_id
  WHERE b.criteria = 'strict'; --- This row is not applied for loose criteria    


--- 2. Intersection - NTIS & WoS
SELECT COUNT(DISTINCT a.ut)
  FROM #ntis_paper_kr_fund_wos_fundertype AS a
  INNER JOIN #ntis_paper_kr_fund_wos AS b ON a.ut = b.ut
  WHERE a.in_ntis = 1 --- Publications registered in NTIS
        AND a.criteria = 'strict'; --- This row is not applied for loose criteria


--- 3. Intersection - NTIS & OpenAlex
SELECT COUNT(DISTINCT a.work_id)
  FROM #ntis_paper_kr_fund_openalex_fundertype AS a
  INNER JOIN #ntis_paper_kr_fund_openalex AS b ON a.work_id = b.work_id
  WHERE a.in_ntis = 1 --- Publications registered in NTIS
        AND a.criteria = 'strict'; --- This row is not applied for loose criteria


--- 4. Intersection - WoS & OpenAlex
SELECT COUNT(*) FROM (
  SELECT DISTINCT a.ut, a.work_id
    FROM #ntis_paper_kr_fund_connect AS a
	INNER JOIN #ntis_paper_kr_fund_wos_fundertype AS b ON a.ut = b.ut
	INNER JOIN #ntis_paper_kr_fund_openalex_fundertype AS c ON a.work_id = c.work_id
	WHERE b.criteria = 'strict' AND c.criteria = 'strict' --- This row is not applied for loose criteria
  ) AS sub;


--- 5. Intersection - NTIS & WoS &OpenAlex
SELECT COUNT(*) FROM (
  SELECT DISTINCT a.ut, a.work_id
    FROM #ntis_paper_kr_fund_connect AS a
	INNER JOIN #ntis_paper_kr_fund_wos_fundertype AS b ON a.ut = b.ut
	INNER JOIN #ntis_paper_kr_fund_openalex_fundertype AS c ON a.work_id = c.work_id
	INNER JOIN [userdb_eums].[dbo].[ntis_matching] AS d ON a.ut = d.wos AND a.work_id = d.openalex
	WHERE b.criteria = 'strict' AND c.criteria = 'strict' --- This row is not applied for loose criteria
  ) AS sub;