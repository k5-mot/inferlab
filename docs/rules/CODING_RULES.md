# コーディングルール

## 基本原則

- 変更は既存のarchitecture、framework、helper、命名規則へ合わせなければならない（MUST）。
- unrelatedなrefactorを機能変更へ混在させてはならない（MUST NOT）。
- codeは、対象言語のformatter、linter、type checker、testを通過しなければならない（MUST）。
- 機密情報、credential、token、passwordをsource codeまたはlogへ記録してはならない（MUST NOT）。
- 外部入力とstructured dataには、利用可能な標準parserまたはlibraryを使用しなければならない（MUST）。

## コメントとドキュメンテーションコメント

- code commentとdocumentation commentは日本語で記述しなければならない（MUST）。
- すべてのfunctionとmethodには、その言語で標準的な形式のdocumentation commentを記述しなければならない（MUST）。
- functionのdocumentation commentには、目的、parameter、return valueを記述しなければならない（MUST）。
- exceptionとside effectがある場合、それらも記述すべきである（SHOULD）。
- codeを言い換えるだけのcommentを記述してはならない（MUST NOT）。commentは理由、制約、設計判断を説明すべきである（SHOULD）。
- TODOには、削除条件、完了条件、または追跡先を記載すべきである（SHOULD）。

## Python

- PEP 8とGoogle Python Style Guideに従わなければならない（MUST）。
- public function、method、classにはGoogle styleのdocstringを記述しなければならない（MUST）。
- command line programは`def main(argv: Sequence[str]) -> int`をentry pointとし、`raise SystemExit(main(sys.argv))`で終了codeを返さなければならない（MUST）。
- `main`の処理時間は`time.perf_counter()`で計測し、loggerへ記録しなければならない（MUST）。
- application logには`print()`を使用せず、`logger.info()`などのloggerを使用しなければならない（MUST）。
- 標準出力自体がcommandのinterfaceである場合に限り、data出力へ`print()`を使用してもよい（MAY）。diagnosticとerrorは標準エラー出力またはloggerへ出力しなければならない（MUST）。
- path操作には文字列連結ではなく`pathlib.Path`を使用すべきである（SHOULD）。
- type hintを付与し、可能な範囲でstatic type checkerを実行すべきである（SHOULD）。

## TypeScriptとJavaScript

- TypeScript codeはMicrosoft TypeScript Coding GuidelinesとGoogle TypeScript Style Guideに従わなければならない（MUST）。
- JavaScript codeはGoogle JavaScript Style Guideに従わなければならない（MUST）。
- 新規codeでは、合理的な理由がない限りTypeScriptを選択すべきである（SHOULD）。
- `any`を安易に使用してはならない（MUST NOT）。外部入力は`unknown`として受け取り、validation後に型を狭めるべきである（SHOULD）。
- exported function、class、typeの意図がsignatureだけで明確でない場合、JSDocを記述しなければならない（MUST）。

## Bash

- executable scriptは`#!/usr/bin/env bash`と`set -euo pipefail`を使用しなければならない（MUST）。
- function直前のcommentには、目的、parameter、return valueを記述しなければならない（MUST）。
- variable展開は、意図的なword splittingが必要な場合を除き、double quoteで囲まなければならない（MUST）。
- destructiveな処理とnetworkを切断する処理には、実行前の検証、明確な警告、可能な場合はrollbackを用意しなければならない（MUST）。
- 利用可能な環境では`shellcheck`を実行すべきである（SHOULD）。

## YAMLとDocker Compose

- service、network、volumeの既存命名規則に合わせなければならない（MUST）。
- versionを固定できるimageで`latest` tagを使用すべきではない（SHOULD NOT）。
- healthcheck、resource limit、restart policyはservice特性と障害時の影響を考慮して設定しなければならない（MUST）。
- Compose変更後は、対象fileを指定して`docker compose config --quiet`を実行しなければならない（MUST）。
- environment variableにsecretの実値をhard-codeしてはならない（MUST NOT）。

## 検証

- behavior変更には、riskと影響範囲に応じたtestを追加または実行しなければならない（MUST）。
- formatterや自動生成によるunrelatedな差分をcommitへ含めてはならない（MUST NOT）。
- testを実行できなかった場合、その理由と未検証範囲をPull Requestへ記載しなければならない（MUST）。

## References

- [PEP 8: Style Guide for Python Code](https://peps.python.org/pep-0008/)
- [Google Python Style Guide](https://google.github.io/styleguide/pyguide.html)
- [TypeScript Coding Guidelines](https://github.com/microsoft/TypeScript/wiki/Coding-guidelines)
- [Google TypeScript Style Guide](https://google.github.io/styleguide/tsguide.html)
- [Google JavaScript Style Guide](https://google.github.io/styleguide/jsguide.html)
- [ShellCheck](https://www.shellcheck.net/)
- [Compose Specification](https://compose-spec.io/)
- [RFC 8174: Ambiguity of Uppercase vs Lowercase in RFC 2119 Key Words](https://www.rfc-editor.org/info/rfc8174/)
