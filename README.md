# XIV 配布データ

このリポジトリは、Dalamud向けの配布manifestと、外部リポジトリのまとめJSONを公開します。

## 公開ファイル

- [`pluginmaster.json`](pluginmaster.json)：WorkSpaceでビルドしたプラグイン
- [`repository-summary.json`](repository-summary.json)：通常側の外部リポジトリまとめ
- [`repository-summary-forks.json`](repository-summary-forks.json)：フォーク・派生側の外部リポジトリまとめ
- [`aetherfeed-summary.json`](aetherfeed-summary.json)：AetherFeedの探索用まとめ

## 更新Actions

更新Actionsはこのリポジトリの[Actions](https://github.com/Na7shi/XIV/actions)で実行します。

| workflow | 自動実行 | 主な用途 |
| :--- | :--- | :--- |
| [Update Repository Summary](.github/workflows/update-repository-summary.yml) | 10分ごと | 通常側・フォーク側の追加、更新、削除を検知してJSONを更新 |
| [Update AetherFeed Summary](.github/workflows/update-aetherfeed-summary.yml) | 6時間ごと | AetherFeed全件と配布元URLを更新 |

どちらも`workflow_dispatch`による手動実行に対応しています。WorkSpaceの
`Build and Deploy Plugin`が成功した場合は、`repository_dispatch`でも通常側のまとめ更新を起動します。

### PowerShellについて

これらのworkflowは、リポジトリ内の`Update-RepositorySummary.ps1`と
`Update-AetherFeedSummary.ps1`を実行するため、GitHub ActionsのWindowsランナー上で
PowerShell 7（`pwsh`）を使用します。`windows-latest`には`pwsh`が標準搭載されているため、
Actions利用者が追加インストールする必要はありません。ローカルでJSONを生成しない限り、
利用者のPCにもPowerShellを用意する必要はありません。

取得先と分類設定は次のファイルで管理します。

- [`repository-sources.json`](repository-sources.json)
- [`repository-summary-fork-sources.json`](repository-summary-fork-sources.json)
- [`repository-summary-exclusions.json`](repository-summary-exclusions.json)

まとめJSONは取得元の配布manifestを加工した一覧です。元の配布zip内manifestやAssembly名は変更していません。
同じ`InternalName`の配布物を同じDalamud環境で完全に共存させるには、配布物側で別の`InternalName`が必要です。
