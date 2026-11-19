# Slime Factory の仕組み

使い方は [README](../README.md) にあります。ここには、アプリが Claude Code をどう起動し、どうつないでいるかを書きます。

## テンプレートとセッション

- テンプレートは `~/Library/Application Support/SlimeFactory/` の `templates.json` と `templates/<id>/AGENTS.md` に保存される
- セッションは `claude --name <スライム名> --session-id <UUID> --append-system-prompt <AGENTS.md の内容>` で起動する
- 起動時の AGENTS.md は `sessions/<UUID>/AGENTS.md` にコピーされ、あとでテンプレートを編集しても起動済みのセッションには影響しない
- 環境変数はログインシェル（`$SHELL -l -i`）から一度だけ読み取り、`claude` はシェルを介さずに直接起動する
- ログインシェルの読み取りは、シェルのプロセスが終わった時点で終える。`.zshrc` が裏で起動したプロセスが出力を開いたままでも待たず、そのプロセスの出力は閉じられるまで裏で受け取って捨てる。シェルが 5 秒で終わらなければ止めて、`PATH` に `~/.local/bin`・`/opt/homebrew/bin`・`/usr/local/bin` を足した値を使う
- ログインシェルの読み取りは、アプリの起動直後に裏のスレッドで始める。読み終わる前にスライムやターミナルを開いたときは、画面を止めずに読み終わるのを待ってから起動し、その間スライムには「起動中」と出す。テンプレートのスライムから新しいスライムを作るときに名前の重複を確かめる処理は、読み終わっていなければアプリ自身の環境変数を使う

## 保存

スライム（テンプレート・位置・名前・設定）、矢印、各スライムの Claude Code のセッション ID を `canvas.json` に 2 秒ごとと終了時に保存する。再起動後にスライムをクリックすると、記録があれば `--resume` で前の会話に戻る。作業ディレクトリと worktree は会話を引き継ぐために固定され、右クリックの「会話をリセット」で次回は新しい会話になる。

## スライムの名前

画面に出す名前は、最初の依頼の 1 行目から付ける。Claude Code がターミナルに要約のタイトルを付けたら、それに置き換える。右クリックの「名前を変える…」で手で付けることもできる。メッセージの宛先（`--name`）はスライムを作ったときの名前のまま変わらない。ただし、このマシンで動いているほかの Claude Code のセッション（`~/.claude/sessions/*.json` に登録された、終了していないプロセス）と同じ名前になるときは、スライムを作るときとセッションを起動するときに「解説-2」のように番号を付けて、宛先が 2 つにならないようにする。

## 状態の絵文字の出どころ

| 絵文字 | 状態 | 出どころ |
|---|---|---|
| 👍 | 完了 | `report_status`（`done`）。報告がないままターンが終わり、最後の返答が質問でないとき |
| 🙋 | 判断を求めている | `report_status`（`need_decision`）、`AskUserQuestion`、質問で終わったターン |
| 🧱 | 進められない | `report_status`（`blocked`） |
| 🔐 | 許可待ち | Notification フック（`permission_prompt`） |
| 📋 | 計画の確認待ち | `ExitPlanMode` |
| ⚠️ | エラーで停止 | StopFailure フック |
| 💤 | 入力待ち | Notification フック（`idle_prompt`） |

`report_status` は各スライムに MCP で渡すツールで、ターンの終わりに呼ぶよう指示している。macOS の通知は `osascript` 経由で出す。

## スライムの大きさ

フックの入力に入っている `transcript_path`（会話の記録ファイル）の末尾 2MB を読み、最後のメインエージェントの応答の `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` をコンテキストの量とする。サブエージェントの応答は数えない。0 トークンで半径 0.8 倍、20 万トークンで 1.5 倍になり、それより先は大きくならない。フックが届くたびに読み直すので、`/compact` の後は次の応答でしぼむ。アプリの起動時にも、保存してある会話の記録（`~/.claude/projects/*/<セッション ID>.jsonl`）から一度読むので、起動前のスライムも会話の量に合った大きさで出る。

## 島とスライムの作業ディレクトリ

ディレクトリの候補は、最近使ったものと `ghq list -p` の一覧。島は `settings.json` に保存される。島同士は重ならない。重なると中のスライムごと押し離し、押された島が画面の端で動けないときは、動かしている島のほうを止める。

スライムの作業ディレクトリは、起動するときに次の順で決まる。

1. スライムごとの指定（右クリック、管理セッション）。管理セッションの `create_bubble` で島か作業ディレクトリを指定したときは、その島のディレクトリをここに記録する
2. スライムが置かれている島。島へ移動している途中なら、向かっている先の島
3. 矢印の送り元のスライムのディレクトリ
4. テンプレートの作業ディレクトリ
5. 最後に使ったディレクトリ

管理セッションが島を指定して作ったスライムは、行き先の島を覚えて移動し、通り道にある別の島には入らない。移動中に行き先の島が押されて動いたら、行き先の位置も一緒にずらす。管理セッションは `configure_bubble` の `island` でスライムを別の島へ移せる。起動前なら作業ディレクトリもその島にする。

起動後に別の島へ動かしてもディレクトリは変わらず、スライムに ⚠ が付く。worktree をオンにしたスライムは、島のディレクトリで `claude --worktree` を使い、`.claude/worktrees/<名前>/` で動く。

## 起動の設定

テンプレートごとの既定値と、スライムごとの上書きを持つ。起動時に次のように渡す。

| 設定 | 渡し方 |
|---|---|
| 作業ディレクトリ | プロセスのカレントディレクトリ |
| サンドボックス | `--settings` の `sandbox`（オン: `enabled: true`、厳格: さらに `allowUnsandboxedCommands: false`） |
| 権限モード | `--permission-mode` |
| worktree | `--worktree <テンプレート id>-<スライム番号>`。既定はオンで、作業ディレクトリが git リポジトリの中のときだけ付ける |
| Chrome 連携 | 既定は指定なし、オンは `--chrome`、オフは `--no-chrome` |
| モデル | `--model`。空欄なら指定しない |
| effort | `--effort`（low・medium・high・xhigh・max）。既定なら指定しない |

サンドボックスの全体の既定はオン（設定の「一般」で変えられる）。テンプレートで「全体の既定」を選ぶとこれに従う。

テンプレートの「候補」には、Claude Code の別名（fable・opus・sonnet・haiku）が出る。

## MCP サーバー

アプリは `127.0.0.1` で MCP サーバー（Streamable HTTP）を動かし、`--mcp-config` で各セッションに渡す。

管理セッションに渡すツールは `list_templates`、`list_bubbles`、`list_islands`、`create_island`、`create_bubble`、`configure_bubble`、`connect_bubbles`、`disconnect_bubbles`、`start_bubble`、`open_file`、`say`。ほかのスライムに渡すツールは `report_status`、`open_file`、`say`。

- `open_file`: Markdown ファイルを画面のエディタで開く。開く前に、「開く / 開かない」を選ぶダイアログを出して人に確かめる
- `say`: そのスライムの横に短い吹き出し（80 文字まで）を出す。新しく出すと前の吹き出しは置き換わり、人がスライムを開くか、`text` を空にして呼ぶと消える。定期的に見回るエージェントが、人に知らせたいことを見つけたときに使う想定

管理セッションとスライムの間の `SendMessage` は、矢印がなくても許可する。

管理セッションが MCP でスライムの設定を緩めようとしたときは、人が承認するまで反映しない。対象は、サンドボックスを弱める変更（厳格 → オン → ユーザー設定 → オフの順に弱い）、権限モードを緩める変更（plan・manual・dontAsk → 既定 → acceptEdits → auto → bypassPermissions の順に緩い）、Chrome 連携をオンにする変更、矢印を「承認なしで送る」にする変更。スライムの下に変更の内容と「許可する / 止める」を出し、許可されたら反映する。`create_bubble` の `start` と `configure_bubble` の `restart` は、承認の判断のあとに行う。強める変更や、ほかの設定はすぐ反映する。

## スライム間の受け渡し

Claude Code の[セッション間メッセージ](https://code.claude.com/docs/en/cross-session-messaging)を使う。スライムの Claude 自身が `SendMessage` で、矢印の先のスライムの名前を宛先にして送る。

- 各セッションは `--settings` で次のフックを付けて起動する。フックはすべて command 型で、`curl` でアプリ内の HTTP サーバー（`localhost`）を呼ぶ。HTTP 型のフックはサンドボックスを有効にすると届かないことがあったため使っていない
  - `PreToolUse`（`SendMessage`）: 矢印のない相手とスライム以外への送信を拒否する。矢印のある相手への送信は、スライムの下に「送る / 止める」を出して人の判断を待つ。矢印が「承認なしで送る」なら、そのまま許可する
  - `PostToolUse`（`SendMessage`）: 送信が済んだら、糸を伝う滴を流す
  - `PreToolUse`（`AskUserQuestion`）: 質問が 1 つで、選択肢が 4 つまでで、複数を選ばないときは、スライムの下に選択肢を出して人の選択を待つ。選ばれたら `permissionDecision: "allow"` と、選んだ答えを `answers` に入れた `updatedInput` を返し、ターミナルを出さずに答える。「ターミナルで答える」を押したときと、スライムのパネルを開いたときは、何も決めずに返してターミナルに質問を出す。条件に合わない質問も、そのままターミナルに出す
  - `PreToolUse`（すべてのツール）、`Notification`、`Stop`: スライムの吹き出しに、いまの作業を出す。サンドボックスがオンのスライムで、Bash の入力に `dangerouslyDisableSandbox: true` があれば、膜の右上を開く。`PostToolUse`、次のツール、`Stop`、`StopFailure`、次の依頼のどれかが届いたら閉じる
  - `UserPromptSubmit`: そのスライムの送り先と受け取り元を、追加のコンテキストとして渡す
  - `SessionStart`: 受信箱の準備ができたことをアプリに知らせる。送り先のセッションが動いていなければ自動で起動し、準備ができてから送信を許可する
- `--append-system-prompt` には、テンプレートの AGENTS.md の前に、引き継ぎの書き方（目的・成果物の場所・依頼内容）を書いた Slime Factory の説明を付ける

## アイコン

Dock のアイコンは `Sources/SlimeFactory/Resources/AppIcon.png` で、起動時に設定する。画面と同じ Metal の描画とスライムの顔で描いたもので、描き方を変えたら次のコマンドで作り直す。

```sh
.build/release/SlimeFactory --icon Sources/SlimeFactory/Resources/AppIcon.png
```
