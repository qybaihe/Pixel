# ClipClashPixel Agent Roundtable Handoff

更新时间：2026-06-06

这份文档用于下一轮继续实现页面和流程对齐：把 ClipClashPixel 从“专家卡片 + Battle 模拟文本”推进到“AI 驱动的像素专家圆桌会议”。

## 当前事实

项目路径：

`/Users/baihe/Documents/New project 22/ClipClashPixel`

主工程：

`/Users/baihe/Documents/New project 22/ClipClashPixel/ClipClashPixel.xcodeproj`

核心 SwiftUI 文件：

`/Users/baihe/Documents/New project 22/ClipClashPixel/ClipClashPixel/ContentView.swift`

Persona manifest：

`/Users/baihe/Documents/New project 22/ClipClashPixel/ClipClashPixel/Resources/ExpertPersonas.json`

背景音乐资源：

`/Users/baihe/Documents/New project 22/ClipClashPixel/ClipClashPixel/VoiceClips/`

已接入：

- `battle.mp3`
- `highlight.mp3`
- `nromal.mp3`

后端入口已经配置好：

- Health: `GET https://ios.classby.cn/clipclash/expert/health`
- Reply: `POST https://ios.classby.cn/clipclash/expert/reply`
- Topic: `POST https://ios.classby.cn/clipclash/topic`

实际部署链路：

`iOS App -> https://ios.classby.cn -> Nginx -> douyin-pi-agent:8788 -> expert_agent_server.mjs -> MiniMax/AI env`

Douyin 议题链路：

`iOS App -> https://ios.classby.cn/clipclash/topic -> douyin-pi-agent:8788/api/clipclash/topic -> /api/douyin/fast -> topic cleaner/fallback`

服务器上只保留主服务：

- `douyin-pi-agent.service`
- 监听 `8788`
- ClipClash expert 路由已挂进 `/home/ubuntu/douyin-pi-agent/scripts/douyin_api_server.mjs`
- Expert handler 在 `/home/ubuntu/douyin-pi-agent/scripts/expert_agent_server.mjs`
- `clipclash-expert-agent.service` 已停用，不再依赖 `8789`

Health 期望返回含：

```json
{
  "ok": true,
  "service": "clipclash-expert-agent",
  "mode": "director-role-agent",
  "parentService": "douyin-pi-agent"
}
```

## API Contract

`POST /clipclash/topic`

请求体：

```json
{
  "url": "https://v.douyin.com/LTkZ2QGryKo/"
}
```

响应体核心：

```json
{
  "ok": true,
  "mode": "clipclash-topic-ai | clipclash-topic-fallback",
  "topic": {
    "title": "AI短剧该不该上位？",
    "debate": "AI短剧冲垮真人剧组，是效率进步还是行业失血？",
    "hook": "AI短剧的兴起对真人短剧行业产生了巨大冲击...",
    "source": "Douyin Clip Import",
    "sourceUrl": "https://v.douyin.com/...",
    "awemeId": "7626683980133190927",
    "authorName": "知危",
    "claims": ["短事实 1", "短事实 2"],
    "controversy": "技术效率 vs 真人创作者生计",
    "suggestedExperts": ["张雪峰", "L", "费曼", "鲁迅", "小八"]
  }
}
```

注意：原始 `/api/douyin/fast` 仍需要服务端密码，iOS 只调用 `/clipclash/topic` 公开代理，不保存密码。

`POST /clipclash/expert/reply`

请求体：

```json
{
  "systemPrompt": "游戏内专家角色系统提示词",
  "persona": {
    "id": "l-lawliet",
    "displayName": "L",
    "role": "冷静推理",
    "category": "动漫推理",
    "skillSourcePath": "l-lawliet-perspective/SKILL.md",
    "coreBelief": "从异常值出发，用概率、实验和验证逼近真相。",
    "speechStyle": "冷静、古怪、礼貌但轻微冒犯，常先给概率判断。",
    "debateStyle": "设计测试场，让对方的观点必须经受异常样本和反例检验。",
    "agreementTriggers": ["证据链", "概率校准", "异常值"],
    "disagreementTriggers": ["没有验证", "只靠直觉"],
    "catchphrases": ["我大约有7%的怀疑。"],
    "safetyNotes": "游戏内风格化人格，不代表真实本人。",
    "defaultVoiceClipName": "l_i_want_to_tell_you_i_am_l",
    "battleBGMName": "battle",
    "highlightBGMName": "highlight",
    "defaultRelationship": {
      "understanding": 4,
      "taming": 1,
      "consensus": 2
    }
  },
  "request": {
    "expertId": "l-lawliet",
    "topic": "先放葱，还是先放盐？",
    "userMessage": "我认为先放盐能稳定出汁，后面更容易判断火候。",
    "scene": "battle",
    "currentPersuasion": 0.36,
    "conversationHistory": []
  }
}
```

响应体：

```json
{
  "text": "专家实际说的话",
  "stance": "support",
  "emotion": "skeptical",
  "persuasionDelta": 0.06,
  "suggestedPetState": "Speaking",
  "shortQuote": "圆桌或卡片短句",
  "memoryNote": "这轮对用户观点的印象沉淀"
}
```

枚举：

- `scene`: `roundtable | battle | libraryPreview`
- `stance`: `support | oppose | swing`
- `emotion`: `calm | excited | skeptical | softened | aggressive | funny`
- `suggestedPetState`: `Speaking | Opposed | Supported`

注意：

- iOS 不保存 API key。
- 线上失败时，iOS `ExpertAIRuntime` 会落回 `MockExpertAIClient`。
- 后端也有 fallback，保证返回合法 `ExpertAIReply`。
- Battle 请求 timeout 当前为 90 秒。

## 已准备专家

总数：30 个 persona。

Skill persona，第一批可重点展示：

- 张雪峰：`07_Public_Internet_Figures/zhangxuefeng-perspective/SKILL.md`
- 小八 / Hachiware：`hachiware-perspective/SKILL.md`
- 奶龙：`daxiao-nailong-perspective/SKILL.md`
- L：`l-lawliet-perspective/SKILL.md`
- 费曼：`01_Science_and_Technology/feynman-skill/SKILL.md`
- Carl Sagan：`01_Science_and_Technology/carl-sagan-perspective/SKILL.md`
- 鲁迅：`03_Politics_Military_and_History/lu-xun-perspective/SKILL.md`
- Andy Warhol：`04_Arts_and_Literature/andy-warhol-perspective/SKILL.md`
- Carl Jung：`04_Arts_and_Literature/carl-jung-perspective/SKILL.md`
- 冯小刚：`05_Media_Entertainment_and_Internet/feng-xiaogang-perspective/SKILL.md`
- 户晨风：`05_Media_Entertainment_and_Internet/hu-chenfeng-skill/SKILL.md`
- 陈丹青：`06_Society_and_Public_Intellectuals/chen-danqing-perspective/SKILL.md`
- 熊大：`xiongda-perspective/SKILL.md`
- Joseph Stalin：`03_Politics_Military_and_History/joseph-stalin-perspective/SKILL.md`，隐藏测试角色

Seed persona，也可以正常被 AI 调用：

- Musk
- Trump
- 豆包
- Claude
- 雷军
- 张一鸣
- Sam Altman
- Einstein
- Newton
- 黄仁勋
- 乌萨奇
- Bubu
- Rilakkuma
- Misa
- 柯南
- 路飞

推荐主推荐位：

- 张雪峰
- 小八
- 奶龙
- L
- 费曼
- Carl Sagan
- 鲁迅
- Andy Warhol
- Carl Jung
- 陈丹青
- 冯小刚
- 户晨风
- 熊大

不要默认主推：

- Joseph Stalin，只作为隐藏测试或 debug 角色。

## 当前 Swift 结构

已有模型：

- `ExpertPersona`
- `ExpertAIRequest`
- `ExpertAIReply`
- `ExpertConversationMessage`
- `ExpertAIClient`
- `MockExpertAIClient`
- `RemoteExpertAIClient`
- `ExpertAIRuntime`
- `ExpertPromptBuilder`
- `ExpertPersonaStore`

核心调用：

- `ExpertAIRuntime.reply(to:)`
- 会优先走 `RemoteExpertAIClient`
- 远端失败则走 `MockExpertAIClient`
- 每次 reply 会写入 `personaStore.record(reply:forExpertId:)`

远端 endpoint 当前默认：

`https://ios.classby.cn/clipclash/expert/reply`

也支持覆盖：

- `UserDefaults.standard.string(forKey: "ExpertAIEndpoint")`
- `Bundle.main.object(forInfoDictionaryKey: "EXPERT_AI_ENDPOINT")`

## 提示词规则

系统提示词必须包含：

- 你正在扮演某个“风格化 AI 专家角色”
- 这是游戏内角色，不要声称你是真实本人
- 必须根据 persona 的思维框架回答
- 必须围绕用户话题给出具体判断
- 必须有一点冲突感，尤其在 Battle 场景
- 不要泛泛而谈
- 不要输出长篇论文
- Battle 回复建议 1-3 句
- 圆桌回复建议 1 句
- 返回 JSON，不要返回散文

推荐系统提示词模板：

```text
你正在扮演一个游戏内的风格化 AI 专家角色，不要声称你是真实本人在线。
角色：{displayName}（{role}）
核心判断方式：{coreBelief}
说话风格：{speechStyle}
典型反驳方式：{debateStyle}
容易被说服的点：{agreementTriggers}
容易反对或被激怒的点：{disagreementTriggers}
边界：{safetyNotes}
必须根据 persona 的思维框架回答，必须围绕用户话题给出具体判断，不要泛泛而谈，不要输出长篇论文。
{sceneLimit}
只返回 JSON，不要返回散文。
```

## 圆桌会议完整流程

目标：让圆桌不是“卡片列表”，而是一场可推进、可分歧、可追问、可进入 Battle 的专家会议。

### 1. 输入议题

来源可以是：

- 用户手动输入话题
- 粘贴抖音链接后生成话题
- 从视频摘要中提取争议点
- 当前 demoTopic

统一产物：

```swift
RoundtableTopic(
    source: String,
    debate: String,
    hook: String,
    title: String,
    sourceUrl: String?,
    awemeId: String?,
    authorName: String?,
    claims: [String],
    controversy: String?,
    suggestedExperts: [String]
)
```

### 2. 选专家

默认选 4-6 个专家：

- 一个现实派，例如张雪峰
- 一个推理派，例如 L
- 一个科学派，例如费曼或 Sagan
- 一个社会观察者，例如鲁迅/陈丹青/户晨风
- 一个趣味角色，例如小八/奶龙/熊大

每个专家必须绑定 persona：

`personaId(forDisplayName:) -> ExpertPersonaStore.persona(forId:)`

如果没有 Skill，就使用 seed persona，不能不可用。

### 3. 开场

进入圆桌页时：

- 播放 `nromal.mp3`
- 每个专家进入 Idle 状态
- 当前主持人/系统抛出议题
- 显示“生成本轮圆桌观点”

可自动触发：

`RoundTableHomeView.generateRoundTableOpinions()`

每个专家发起：

```swift
ExpertAIRequest(
    expertId: expertId,
    topic: topic,
    userMessage: "请基于当前话题给出一句圆桌观点，并和其他专家保持一点立场差异。",
    scene: .roundtable,
    currentPersuasion: nil,
    conversationHistory: []
)
```

返回后更新：

- 专家短句气泡：`reply.shortQuote` 或 `reply.text`
- 站队：`reply.stance -> Expert.Side`
- 动画状态：`reply.suggestedPetState`
- 记忆：`reply.memoryNote`

### 4. 交锋轮

一轮圆桌建议包含：

1. 主持人提出议题
2. 每位专家给一句立场
3. 系统根据 stance 生成阵营：
   - support 阵营
   - oppose 阵营
   - swing 阵营
4. 自动挑选冲突对：
   - 例如 support vs oppose
   - 或当前选中专家 vs 反对最强专家
5. 显示“冲突焦点”

可存状态：

```swift
RoundtableRound(
    id: UUID,
    topic: String,
    expertReplies: [ExpertRoundReply],
    conflictFocus: String,
    selectedDebateExpertId: String?
)
```

```swift
ExpertRoundReply(
    expertId: String,
    text: String,
    stance: ExpertStance,
    emotion: ExpertEmotion,
    petState: ExpertPetState,
    shortQuote: String,
    memoryNote: String
)
```

### 5. 进入 Battle

用户点击某个专家：

- 带入当前 topic
- 带入该专家刚才的 `shortQuote/text`
- 带入该专家 stance
- Battle 页面播放 `battle.mp3`
- 专家登场/高光时播放 `highlight.mp3`

Battle 的首屏建议显示：

- 专家刚才圆桌观点
- 当前不服值
- 说服度
- 开放度
- “开麦说服战”按钮

Battle 请求：

```swift
ExpertAIRequest(
    expertId: personaId,
    topic: topic,
    userMessage: transcriptOrMockLine,
    scene: .battle,
    currentPersuasion: Double(persuasion),
    conversationHistory: history
)
```

返回后更新：

- 回复气泡：`reply.text`
- stance：`reply.stance`
- emotion：`reply.emotion`
- 不服值：根据 `persuasionDelta` 反向变化
- 说服度：`persuasion += persuasionDelta`
- 开放度：由 persuasion 推导
- petState：`reply.suggestedPetState`
- memory：`reply.memoryNote`

视觉规则：

- `suggestedPetState == Speaking`：普通说话动画
- `suggestedPetState == Opposed`：更强反驳状态
- `suggestedPetState == Supported`：支持/软化状态
- `persuasionDelta >= 0.16`：显示“立场松动”
- `stance == oppose`：显示“更强反驳”
- `stance == support`：显示“支持状态”

### 6. Battle 回流圆桌

Battle 结束或返回圆桌时：

- 把 `memoryNote` 写回该专家 persona relationship memory
- 更新专家库关系条
- 更新圆桌中该专家的短句或态度
- 若 persuasion 超过阈值，专家 stance 可从 oppose -> swing -> support

建议阈值：

- `persuasion < 0.35`：强反对
- `0.35...0.65`：摇摆
- `> 0.65`：支持或软化

### 7. 专家库联动

专家库卡片要显示：

- persona `coreBelief` 的短摘要
- 接受点：`agreementTriggers`
- 雷区：`disagreementTriggers`
- 当前 relationship metrics：
  - understanding
  - taming
  - consensus
- Battle 后根据 `persuasionDelta` 更新这些条

长按专家卡：

```swift
ExpertAIRequest(
    expertId: expertId,
    topic: topic,
    userMessage: "请给出这个专家对当前话题的登场态度，一句话即可。",
    scene: .libraryPreview,
    currentPersuasion: nil,
    conversationHistory: []
)
```

返回后显示：

- `reply.shortQuote` 优先
- 没有则 `reply.text`

## 页面体验对齐

### 专家库

要从“展示卡”变成“可召唤角色库”：

- 卡片主视觉仍是像素宠物
- 明确显示“接受点”
- 明确显示“雷区”
- 关系条由 personaStore 的 runtime state 驱动
- 长按预览触发 AI 登场态度
- 加入圆桌时播放 `highlight.mp3`

### 圆桌

要从“静态圆桌”变成“会议现场”：

- 顶部是当前议题
- 中间是专家席位和气泡
- 每轮有生成状态
- 每位专家短句必须来自 `ExpertAIClient`
- stance 要可视化：支持、反对、摇摆
- 选中专家可进入 Battle
- 普通浏览播放 `nromal.mp3`

### Battle

要从“模拟回复”变成“说服战”：

- 点击麦克风进入 listening
- 结束后生成 transcript，当前可以先保留模拟输入
- 显示 typing/thinking
- 调用 `ExpertAIClient`
- 回复回来后驱动气泡、条形指标、动画状态、memory
- 背景播放 `battle.mp3`
- 高光/登场播放 `highlight.mp3`

## 后续实现任务

优先级 P0：

- 已完成：iOS 所有专家回复调用经过 `ExpertAIRuntime.reply(to:)`
- 已完成：抖音链接通过 `/clipclash/topic` 导入 `RoundtableTopic`
- 已完成：圆桌每一轮观点来自 AI，并发生成，返回后更新短句和 stance
- 已完成：Battle 麦克风流程调用线上 API；失败时 Mock fallback
- 已完成：专家库长按预览可触发 `.libraryPreview`
- 已完成：Battle/圆桌/预览回复会通过 `personaStore.record` 写入 runtime memory 和关系条

优先级 P1：

- 新增 `RoundtableRound` / `ExpertRoundReply` 状态，保存每轮圆桌发言
- 在圆桌页显示阵营和冲突焦点
- 已完成基础版：从圆桌观点进入 Battle 时，开场会带入该专家刚才观点
- 专家库 relationship metrics 做持久化
- 把 Battle 结束后的 stance 回流更新圆桌当前专家气泡和阵营

优先级 P2：

- 接真实语音识别 transcript
- 加入会议主持人/导演 Agent，为每轮挑冲突焦点
- 加入多专家互相引用上一轮观点
- 加入隐藏角色开关和 debug persona 面板

## 验证命令

后端 health：

```bash
curl -sS https://ios.classby.cn/clipclash/expert/health
```

抖音议题导入：

```bash
curl -sS --max-time 90 https://ios.classby.cn/clipclash/topic \
  -H 'content-type: application/json' \
  --data-binary '{"url":"https://v.douyin.com/LTkZ2QGryKo/"}'
```

iOS 编译：

```bash
xcodebuild -project '/Users/baihe/Documents/New project 22/ClipClashPixel/ClipClashPixel.xcodeproj' -scheme ClipClashPixel -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

注意：

- 之前指定的无签名 build 已通过。
- 如果要 `simctl install`，本机资源的 `com.apple.provenance` 扩展属性可能影响签名/安装；这不是 Swift 编译错误。

## 给下一轮 Codex 的提示词

```text
你现在接手 ClipClashPixel iOS SwiftUI 项目，路径：
/Users/baihe/Documents/New project 22/ClipClashPixel

目标：
继续打磨已经跑通的“抖音链接 -> AI 辩题 -> AI 专家圆桌 -> Battle 说服战 -> 专家库关系沉淀”完整链路。

已完成事实：
1. 后端真实 API 已上线：
   - GET https://ios.classby.cn/clipclash/expert/health
   - POST https://ios.classby.cn/clipclash/expert/reply
   - POST https://ios.classby.cn/clipclash/topic
2. 后端实际运行在服务器 pi 环境：
   ios.classby.cn -> Nginx -> douyin-pi-agent:8788
   expert reply 走 expert_agent_server.mjs 的 director-role-agent
   topic import 走 /api/clipclash/topic，再调用受保护的 /api/douyin/fast
3. iOS 端已有：
   - ExpertPersona
   - ExpertAIRequest
   - ExpertAIReply
   - RoundtableTopic
   - DouyinTopicClient
   - ExpertAIClient
   - MockExpertAIClient
   - RemoteExpertAIClient
   - ExpertAIRuntime
   - ExpertPersonaStore
4. RemoteExpertAIClient 不写 API key，只调用后端代理。
5. ExpertAIRuntime 远端失败会 fallback 到 Mock。
6. Persona manifest 在：
   /Users/baihe/Documents/New project 22/ClipClashPixel/ClipClashPixel/Resources/ExpertPersonas.json
7. 已准备 30 个 persona，其中 Skill persona 包含：
   张雪峰、小八、奶龙、L、费曼、Carl Sagan、鲁迅、Andy Warhol、Carl Jung、冯小刚、户晨风、陈丹青、熊大、Joseph Stalin hidden。
8. MP3 已放在：
   /Users/baihe/Documents/New project 22/ClipClashPixel/ClipClashPixel/VoiceClips/
   battle.mp3、highlight.mp3、nromal.mp3
9. 圆桌页已能粘贴抖音链接，调用 /clipclash/topic，导入 title/debate/hook/claims/controversy/suggestedExperts。
10. 导入 topic 后会按 suggestedExperts 自动调整圆桌席位，随后并发调用 scene=roundtable 生成观点。
11. 圆桌舞台可点击专家选中，中间语音按钮或专家条 Battle 按钮进入 Battle。
12. Battle 开场会带入该专家刚才的圆桌观点，麦克风结束后调用 scene=battle。
13. 专家回复接口和 topic 接口都有服务端 fallback；iOS 端还有 Mock fallback。

请直接实施，不要只写方案。

下一步页面目标：
1. 专家库：
   - 已有接受点和关系条，继续加“雷区 disagreementTriggers”可视化。
   - relationship metrics 做本地持久化。
2. 圆桌：
   - 新增 RoundtableRound / ExpertRoundReply，保存每轮发言。
   - 显示支持/反对/摇摆阵营和冲突焦点。
   - 让专家互相引用上一轮观点，形成真正的多轮会议。
3. Battle：
   - 接真实语音识别 transcript，替换当前模拟输入。
   - Battle 返回圆桌时，把最新 stance/shortQuote 回流到圆桌。
   - 增加“说服成功/失败”收束状态。
4. 音频：
   - 专家库/圆桌播放 nromal.mp3。
   - Battle 播放 battle.mp3。
   - 专家登场/高光播放 highlight.mp3。
   - 避免多个 BGM 同时播放。

重点：
- 不要在 iOS 写 API key。
- 不要把 Skill 长文塞进 UI。
- 角色回复是“游戏内风格化人格”，不要声称真实本人在线。
- 保留 Mock fallback。
- 完成后必须跑：
  xcodebuild -project '/Users/baihe/Documents/New project 22/ClipClashPixel/ClipClashPixel.xcodeproj' -scheme ClipClashPixel -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' -configuration Debug CODE_SIGNING_ALLOWED=NO build
```
