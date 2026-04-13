# README

This repository contains MSSQL scripts used in:

> Eum, S. (2026). Assessing Funders’ Databases Against Bibliographic Sources: A Study of Interoperability, Metadata Quality, and Coverage Using South Korea’s National R&D Database. https://doi.org/10.31235/osf.io/aqfr5_v1

## Contents

- `1. ntis_openalex_matching.sql`: Matching corresponding documents between NTIS and OpenAlex (Section 4)
- `1. ntis_wos_matching.sql`: Matching corresponding documents between NTIS and WoS (Section 4)
- `2. wos_openalex_comparison.sql`: Metadata consistency between WoS and OpenAlex records matched to NTIS (Section 5)
- `3. coverage_comparison.sql`: Coverage of Korean-funded publications across NTIS, WoS, and OpenAlex (Section 7)

## Data Access

NTIS records used in this study can be obtained by applying through the NTIS website: https://www.ntis.go.kr/rndgate/eg/oneMain/OneIndex.do

- Account registration on the NTIS website is required
- The application and approval process are conducted exclusively in Korean; no English-language interface is currently available

## Notes

Data are not redistributed in this repository. Reproduction requires independent access to NTIS and bibliographic databases.
