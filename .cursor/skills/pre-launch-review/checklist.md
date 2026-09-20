# 上线前审查条款速查

对照 [`docs/上线前审查标准.md`](../../../docs/上线前审查标准.md)。审查时按域勾选；无命中写「未发现」而不是省略。

---

## 性能（P）

| # | 查 | 级别要点 |
|---|----|----------|
| P1 | 热路径 `Instance.new` / `Clone` / 无池特效 | 热路径 🔴；打开 UI 🟡 |
| P2 | 热路径 `GetChildren` / `FindFirstChild` / `WaitForChild` | 热路径 🔴；打开 UI 🟡 |
| P3 | `while true do wait()`、弃用 spawn/wait、空转 Heartbeat | while+wait 🔴；多余心跳 🟡 |
| P4 | 按玩家连接 / `userId` 表未随离开释放 | 按玩家 🔴；单例 🟡 |
| P5 | 热路径 wait / Http / DataStore / InvokeServer | 🔴 |
| P6 | 结算包无限频；技能未独立 Channel | 结算高频 🔴；表现错通道 🟡 |
| P7 | 同函数反复 GetPlrData / 同 id CfgFind | 🟡 |
| P8 | 伤害数字等成对 new+Destroy，未走对象池 | 🟡 |
| P9 | 预加载只进不出；释放 API 未被调用 | 🟡 + 需实测 |

## 数据安全（S）

| # | 查 | 级别要点 |
|---|----|----------|
| S1 | 客机上报击杀/完成/伤害/掉落当最终事实 | 🔴 §1.6 |
| S2 | 领奖只信客机 CFrame | 🔴 |
| S3 | 绕过 SystemDataStore / ChangeStat | 🔴（CDK / GA Store 排除） |
| S4 | Remote 缺 会话→类型→业务 校验 | 经济 🔴；设置 🟡 |
| S5 | 价格/数量/itemId 信客户端 | 🔴 |
| S6 | DEBUG_* / GM：列出门禁与白名单 | 无门禁无白名单 🔴；有白名单须专节点名 |
| S7 | ProcessReceipt 非幂等 / 错绑 ProductId | 🔴 |
| S8 | 查询 API 返回可写配置原表 | 🔴 |
| S9 | InvokeClient / OnClientInvoke | 🔴 |
| S10 | 回堆栈或整份 PlayerData | 堆栈/存档 🔴；模糊串 🟡 |
| S11 | 领取/购买/兑换无限频 | 经济 🔴 |
| S12 | 存档 Vector3/Instance；Init 里版本迁移 | 🔴 |
| S13 | 位姿/WalkSpeed 多写口 | 🔴 §1.7 |
| S14 | FireAllClients 带他人隐私或整包会话 | 🔴 |

## 本地化（L）

| # | 查 | 级别要点 |
|---|----|----------|
| L1 | 展示句直接赋 Text / ActionText | 🔴 |
| L2 | Key 非字面量、非 Zh* | 🔴 |
| L3 | Key 不在 Language；格子仍 /e | 🔴 |
| L4 | addText 拼数量/时间/物品名 | 支付/任务 🔴；其它 🟡 |
| L5 | SetRawText 用在整句 | 整句 🔴 |
| L6 | {1}{2} 与 args 个数不对 | 🟡 |
| L7 | 手改 Language / ConfigInstance | 确认手改 🔴；打表新鲜度需人工 |
| L8 | Studio 静态 UI 标签 | **需人工**，勿假装已扫 |
| L9 | 克隆列表被「代码本地化」冲后缀 | 🟡 |

## 玩法逻辑（G）

从写存档函数往回追：谁调用、数据从哪来、失败回滚吗、能执行两次吗。

| # | 查 | 级别要点 |
|---|----|----------|
| G1 | 发奖与扣费非原子 | 🔴 |
| G2 | 领取先判断后标记，可双领 | 🔴 |
| G3 | count≤0 / 非整数 / tonumber 失败仍结算 | 🔴 |
| G4 | 配置 nil 仍 ChangeStat | 🔴 |
| G5 | 满包或发奖失败被吞 | 付费/邮件可消失 🔴；语义不清 🟡；**不指定策略** |
| G6 | 技能命中清单 / 伤害信客户端 | 🔴 |
| G7 | CD/消耗/锁只在客户端 | 🔴 |
| G8 | 传送目的地信客户端 | 🔴 |
| G9 | 坐骑/用物不校验所有权 | 🔴 |
| G10 | 进度只靠「我完成了」 | 🔴 |
| G11 | 死亡/锁/坐骑状态机缺口 | 能结算 🔴；只卡表现 🟡 |
| G12 | 测试闸、作弊开关正式服仍加载 | 🔴 |
| G13 | 客户端写 leaderstats / 上报上榜 | 🔴 |
| G14 | 条件反了、扣费用加 | 经济/胜负 🔴 |
| G15 | pcall 失败半更新；空 pcall 吞发奖 | 🔴 |
| G16 | AFK_MOVE 变成传送或刷奖 | 会结算 🔴 |

## 需实测（T）— Agent 不得勾「已通过」

| # | 项 |
|---|---|
| T1 | 20 人战斗高峰 |
| T2 | 进出图内存台阶 |
| T3 | 中英切语言，搜未本地化-、/e |
| T4 | Studio 静态 UI 抽检 |
| T5 | 商店：成功 / 钱不足 / 满包 / 连点 |
| T6 | 每日与邮件：成功 / 连点 / 重进 |
| T7 | Robux：一次购买 + 杀进程 + 重复收据 |
| T8 | 非白名单打 DEBUG_* 应被拒 |
