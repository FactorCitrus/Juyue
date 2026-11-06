# 知识产权投诉与下架通道

本文件说明：权利人如何就 **橘阅 Juyue** 仓库及其发布物提出侵权主张，以及我们会怎么处理。

适用范围：本 GitHub 仓库内的全部文件（源码、文档、图片、构建产物），以及本仓库 Releases 页面下发的安装包。
**不适用**：任何第三方站点的内容、任何第三方书源及其指向的资源、其他开发者 fork 后自行发布的版本。这些不在我们的控制范围内，请向实际运营者主张。

---

## 1. 提交方式

任一渠道均可，建议同时发一封邮件留痕：

| 渠道 | 地址 |
|---|---|
| 邮箱 | **Deathandfly@outlook.com**，主题前缀加 `[IP投诉]` |
| GitHub Issue | 在 Issues 新建，标题前缀 `[IP]`，正文注明「请勿公开传播，请求协处理」 |

工作日 24 小时内回执；非工作日顺延至下一个工作日。

## 2. 需提供的材料

材料不齐会拖慢处理，请一次给全：

1. **权利证明**：著作权登记证书、独家授权合同、出版/发行资质，或其他能证明权属的文件；代理投诉的，附授权委托书。
2. **作品清单**：主张权利的每部作品名称、作者、权利类型（复制权 / 信息网络传播权等）。
3. **具体定位**：涉事文件的仓库路径或 commit、Releases 里的文件名与版本号，**精确到能被检索到的字符串**。只说「你的软件能看盗版小说」无法处理。
4. **侵权说明**：一句话说清是哪一步构成侵权（例如「贵仓库某文件内置了指向我司内容的解析规则」）。
5. **联系方式**：真实姓名或单位、可回复的邮箱、电话（可选）。
6. **真实性声明**：一句「本人/本单位保证上述信息真实，愿承担不实投诉的法律责任」。

## 3. 处理时限与措施

| 阶段 | 时限 | 动作 |
|---|---|---|
| 回执 | 24 小时内 | 确认收到，告知受理编号与预计完成时间 |
| 初核 | 72 小时内 | 核对材料完整性，必要时向被投诉方转达并听取说明 |
| 处置 | 初核通过后 72 小时内 | 采取下述措施之一并书面告知 |

可采取的处置：

- 删除或替换涉事文件；
- 撤回或下架 Releases 中的对应安装包；
- 在仓库显著位置发布说明，澄清与本项目无关的第三方行为；
- 材料明显不成立的，书面说明理由后不予处理。

处置完成后在本仓库 `docs/legal/` 下留档（不公开投诉人身份信息），记录受理编号、处置时间与措施。

## 4. 反通知

被处置方如认为处理有误，可在收到通知后 14 日内提交反通知，附权属或授权依据。双方主张冲突且无法通过材料判断的，我们维持下架状态，并建议双方通过司法或行政途径解决——我们不具备认定权属的资格。

## 5. 我们不做什么

- 不代为判断作品权属，不充当裁判；
- 不处理第三方站点的内容，也无权删除他人服务器上的数据；
- 不对「用户自己导入的规则」承担审核义务，但收到明确指向本仓库文件的投诉时会核查并处置。

## 6. 投诉模板

```text
主题：[IP投诉] <作品名称> - 橘阅 Juyue

一、投诉人
姓名/单位：
证件或统一社会信用代码（可选）：
邮箱：            电话（可选）：

二、权利依据
作品名称：
作者：
权属文件：<登记号 / 合同编号 / 其他>

三、被投诉内容
仓库路径或 Release 文件名：
版本号：
具体位置：<文件名:行号 / commit / 可在页面检索到的字符串>

四、侵权说明
<一段话，说明上述内容如何侵犯了哪一项权利>

五、诉求
<删除 / 下架 / 发布澄清 / 其他>

六、声明
本人/本单位保证上述信息真实，愿承担不实投诉的法律责任。
签名：            日期：
```

## 7. English summary

If you are a rights holder and believe that any file in this repository or any
artifact published under this repository's Releases infringes your rights,
email **Deathandfly@outlook.com** with the subject prefix `[IP]`.

Please include: proof of ownership, the work(s) at issue, the exact repository
path or release filename, a short explanation of the infringement, your contact
details, and a statement of accuracy. We acknowledge within 24 hours (business
days), verify within 72 hours, and remove or withdraw the identified material
within 72 hours of verification.

Third-party book sources, third-party sites, and forks published by other
developers are outside our control; please contact their operators directly.
