# Nextcloud 防衛関連ドキュメント整理リスト

更新日: 2026-07-26 JST

OIKB 読み込み対象: `admin/files/oikb/jsdf`、`admin/files/oikb/dow`

手動確認用リスト: `12-storage/LIST.md`

## 整理方針

- `admin` ユーザーの `oikb` 配下には `jsdf` と `dow` だけを残す。
- `jsdf` には防衛省・自衛隊関連の 2024 年以降の PDF を格納する。
- `dow` には米国防総省・米軍関連の 2024 年以降の PDF を格納する。
- `LIST.md` は OIKB の読み込み対象外にするため、Nextcloud には配置しない。
- 2023 年以前に公表された資料、Nextcloud 初期サンプル、取得失敗マーカー `.url` は `Documents` から削除する。

## 格納済み: jsdf

| ファイル | 出典 |
| --- | --- |
| `Japan_MOD_Defense_of_Japan_2024_Main.pdf` | https://www.mod.go.jp/j/press/wp/wp2024/pdf/R06zenpen.pdf |
| `Japan_MOD_Defense_of_Japan_2024_Reference.pdf` | https://www.mod.go.jp/j/press/wp/wp2024/pdf/R06shiryo.pdf |
| `Japan_MOD_Defense_of_Japan_2024_Chronology.pdf` | https://www.mod.go.jp/j/press/wp/wp2024/pdf/R06nenpyo.pdf |
| `Japan_MOD_Defense_of_Japan_2025_Main.pdf` | https://www.mod.go.jp/j/press/wp/wp2025/pdf/R07zenpen.pdf |
| `Japan_MOD_Defense_of_Japan_2025_Reference.pdf` | https://www.mod.go.jp/j/press/wp/wp2025/pdf/R07shiryo.pdf |
| `Japan_MOD_Defense_of_Japan_2025_Chronology.pdf` | https://www.mod.go.jp/j/press/wp/wp2025/pdf/R07nenpyo.pdf |
| `Japan_MOD_Defense_of_Japan_2025_US_section.pdf` | https://www.mod.go.jp/j/press/wp/wp2025/pdf/R07010301.pdf |
| `Japan_MOD_Defense_of_Japan_2025_JSDF_organization.pdf` | https://www.mod.go.jp/j/press/wp/wp2025/pdf/R07020402.pdf |
| `Japan_MOD_Defense_of_Japan_2025_Japan_US_security_arrangements.pdf` | https://www.mod.go.jp/j/press/wp/wp2025/pdf/R07030201.pdf |
| `Japan_MOD_Defense_of_Japan_2025_Japan_US_deterrence_response.pdf` | https://www.mod.go.jp/j/press/wp/wp2025/pdf/R07030202.pdf |
| `Japan_MOD_Defense_of_Japan_2025_USFJ_presence.pdf` | https://www.mod.go.jp/j/press/wp/wp2025/pdf/R07030205.pdf |

## 格納済み: dow

| ファイル | 出典 |
| --- | --- |
| `US_DoW_National_Defense_Strategy_2026.pdf` | https://media.defense.gov/2026/Jan/23/2003864773/-1/-1/0/2026-NATIONAL-DEFENSE-STRATEGY.PDF |
| `US_DoW_FY2026_Defense_Budget_Overview.pdf` | https://comptroller.war.gov/Portals/45/Documents/defbudget/FY2026/FY2026_Budget_Request_Overview_Book.pdf |
| `US_DoW_FY2026_Program_Acquisition_Costs_by_Weapon_System.pdf` | https://comptroller.war.gov/Portals/45/Documents/defbudget/FY2026/FY2026_Weapons.pdf |
| `US_DoW_FY2026_Pacific_Deterrence_Initiative.pdf` | https://comptroller.war.gov/Portals/45/Documents/defbudget/FY2026/FY2026_Pacific_Deterrence_Initiative.pdf |
| `US_DoW_FY2026_Mandatory_Funding_Overview.pdf` | https://comptroller.war.gov/Portals/45/Documents/defbudget/FY2026/DoD_FY2026_Mandatory_Funding_Overview.pdf |
| `US_DoW_AI_Strategy_2026.pdf` | https://media.defense.gov/2026/Jan/12/2003855671/-1/-1/0/ARTIFICIAL-INTELLIGENCE-STRATEGY-FOR-THE-DEPARTMENT-OF-WAR.PDF |
| `US_DoD_China_Military_Power_Report_2024.pdf` | https://media.defense.gov/2024/Dec/18/2003615520/-1/-1/0/MILITARY-AND-SECURITY-DEVELOPMENTS-INVOLVING-THE-PEOPLES-REPUBLIC-OF-CHINA-2024.PDF |
| `US_STRATCOM_2026_Posture_Statement.pdf` | https://www.stratcom.mil/Portals/8/Documents/Posture%20Statements/2026%20USSTRATCOM%20Congressional%20Posture%20Statement.pdf?ver=Hb98LGT3_5gb01-f_KLHhQ%3D%3D |
| `US_DoD_Arctic_Strategy_2024.pdf` | https://media.defense.gov/2024/Jul/22/2003507411/-1/-1/0/DOD-ARCTIC-STRATEGY-2024.PDF |
| `US_DoD_Countering_Unmanned_Systems_Fact_Sheet_2024.pdf` | https://media.defense.gov/2024/Dec/05/2003599149/-1/-1/0/FACT-SHEET-STRATEGY-FOR-COUNTERING-UNMANNED-SYSTEMS.PDF |

## 手動ダウンロード対象

現時点ではなし。

## References

- https://www.mod.go.jp/j/press/wp/
- https://www.mod.go.jp/j/press/wp/wp2025/pdf/index.html
- https://www.mod.go.jp/en/publ/w_paper/wp_2024.html
- https://www.war.gov/News/Releases/Release/Article/3986597/dod-announces-strategy-for-countering-unmanned-systems/
- https://www.war.gov/News/News-Stories/Article/Article/3846323/new-dod-strategy-calls-for-enhancements-engagements-exercises-in-arctic/
- https://comptroller.war.gov/Portals/45/Documents/defbudget/FY2026/FY2026_Budget_Request_Overview_Book.pdf
