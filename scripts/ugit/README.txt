配置打表钩子 — 最简说明
====================

更新公告（1.6.29）
  - 「打表并提交」按磁盘全量生成并 git add luau（同 1.6.27，不再 isolate）。
  - 修：嵌套 powershell 的打表日志不再污染退出码，第二次拷贝会真正执行（否则只交 xlsx、luau 不变）。
  - 「不打表」仍只校验，并从索引还原 src luau。
  - 已修好的区外表留在修改区、只提交其它表：全量校验通过即可，不再报「暂存区与工作区不一致」拦提交。
  - Cursor 源码管理面板有 Bug（3.15.6 起跳过 git 钩子），不会打表。
    程序和策划改表后都请用 UGit 客户端提交（或终端 git commit）。
  - pull 后若弹「钩子过期」：点一键更新，或双击 1-安装或更新打表钩子.bat。

做什么
  1) 钩子版本：每次 commit / push 都会比对 scripts/ugit/VERSION 与本机已装钩子；
     过期则弹窗并可一键更新（不依赖是否改 Excel）
  2) 工作区（暂存 + 未暂存 + 未跟踪）只要有 config/**/*.xlsx 变化，commit 就会弹窗
     （不能静默打表或静默跳过）：
     - 打表并提交：先按工作区全量表校验；未勾选不加入区外表；luau 按磁盘全量生成并加入提交。提交说明加前缀「【已打表】」
     - 不打表并提交：同样按工作区全量表校验，通过才提交；不改 src 里的 luau，也不把 luau 加入提交（不加入区外表）。提交说明加前缀「【未打表】」
     - 勾选（默认关）：把暂存区外的配置变化也 git add，再一起打表上传
     - 关闭窗口：取消本次提交
     暂存区没有配置表时，须先勾选才能「打表并提交」。
     工作区也没有 xlsx 变化则不弹窗。确认脚本缺失则中止提交，不会静默打表。
     config/.build 下同名 lua 仅本机保留，不上传
  3) 拉取：本仓库 .gitconfig 约定 git pull 使用 rebase（避免 Merge branch 'main' of ...）
  4) merge 安全网：若仍触发 merge commit，pre-merge-commit 会拦截并弹窗；
     可按按钮执行 abort / pull --rebase / stash 后 rebase（推荐「abort 并 rebase 拉取」）
  5) 推送前若本地与远端分叉/落后：弹窗确认后执行 rebase，并中止本次 push，
     成功后请重新推送（避免 merge commit；同一次 push 不会带上 rebase 后的新 SHA）
  6) 单分支协作（大家都在 main）：已启用 git.autoStash；
     仍可用 git ugit-sync 手动触发安全同步
  7) Cursor / VS Code 源码管理面板（3.15.6 起，已知 Bug）会跳过 git 钩子，
     面板提交、推送不会打表。程序、策划改 Excel 后都用 UGit 提交。
     也可先双击 3-本地打表测试.bat 生成 luau，再在面板里交已生成的文件。

谁提交都用 UGit
  程序改配置表 / 本地化表，同样走 UGit 打表提交，不要用 Cursor 面板。

策划怎么用
  1. 确保本地有 scripts/ugit（全量仓库或 sparse 勾选 scripts/ugit/）
  2. 首次（或钩子提示过期时）双击：
       1-安装或更新打表钩子.bat
     （安装 pre-commit / pre-push / pre-merge-commit，并启用 pull.rebase）
     若仓库根无 .gitconfig（如 sparse 只拉 scripts/ugit），安装脚本会自动从
     scripts/ugit/repo.gitconfig 复制到仓库根。
     安装时若 .vscode/settings.json 已含正确 git.path / autoStash，不会重写（避免无意义 diff）。
  3. 改完 Excel、提交前想先本地测试：双击
       3-本地打表测试.bat
     （更新 .build + src，不提交；测完再正常提交）
  4. 之后正常用 UGit/git 提交与推送即可

Sync 被「请清理工作树」拦住时（单分支 main）
  - 终端 git pull 应弹出 UGit 窗；点「一键：stash 并拉取」
  - Cursor 面板同步若只有 IDE 提示、没有 UGit 窗：终端 git ugit-sync
  - 或：先用终端/UGit 提交本地改动，再点「同步更改」

误触发 merge 被拦截时
  弹窗已提供一键/分步按钮；推荐点「一键：取消 merge 并 rebase 拉取」。
  有未提交改动时优先「stash 后 rebase」。
  有冲突：改文件 → git add … → git rebase --continue

rebase 冲突时
  - 解决冲突后：git add ... && git rebase --continue
  - 放弃本次 rebase：git rebase --abort
  - 有未提交改动时 rebase 可能自动 stash；完成后可用 git stash list 查看

缺 Python / 版本过低时
  打表需要 Python 3.10+（推荐 3.12）。PATH 上的 3.9 会被自动跳过。
  双击：2-安装Python环境.bat
  或在弹窗里点「一键安装 Python」

日常不用点
  其它 .ps1 / .py / BuildConfig 等内部文件可忽略。

当前版本见同目录 VERSION。
