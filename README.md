# 银行采集助手

这是一个本地半自动银行页面采集工具。它负责打开银行页面、进入全屏、登录后读取当前页面并按任务规则导出数据。账号、密码、验证码、U盾确认等登录动作需要人工完成。

## 文件说明

- `启动工行网银.hta`：双击运行的界面入口。
- `banks.json`：银行和采集任务配置。
- `accounts.json`：账户列表配置，只保存账户名称、银行、卡号后四位和默认任务。
- `bank-agent.ps1`：通用采集引擎，读取 `banks.json` 后连接 Edge 当前页面。
- `focus-account.ps1`：可选的输入框聚焦辅助脚本。

## 使用流程

1. 双击 `启动工行网银.hta`。
2. 在账户列表里添加或编辑账户，只填写账户名称、银行、卡号后四位和默认任务。
3. 点击该账户行里的“启动页面”。
4. 手动完成登录。
5. 点击该账户行里的“开始采集”。
6. 查看同目录下生成的 `csv`、`json`、`txt` 文件。多账户运行时，输出文件名会带上账户 ID，避免互相覆盖。

账户配置不会保存完整账号、密码、验证码或 U 盾信息。卡号后四位会传给采集引擎，用来辅助确认当前页面上的账户区域是否匹配目标账户。

## 新增银行

在 `banks.json` 的 `banks` 数组里新增一个对象：

```json
{
  "id": "example-bank",
  "name": "示例银行",
  "startUrl": "https://example.com/login",
  "matchUrl": "example.com",
  "matchTitle": "Example",
  "profileDir": "edge-example-bank-profile",
  "debugPort": 9223,
  "focus": {
    "enabled": false,
    "xRatio": 0.5,
    "yRatio": 0.5,
    "label": "登录区域"
  },
  "tasks": [
    {
      "id": "balance",
      "name": "采集余额线索",
      "kind": "keyword-scan",
      "outputPrefix": "example-balance",
      "keywords": ["余额", "可用余额"]
    }
  ]
}
```

## 任务类型

- `keyword-scan`：扫描当前页面中包含关键词的表格、区块、按钮和链接。
- `snapshot`：导出当前页面的动作入口、表格和表单结构，适合第一次摸索新银行页面。

后续如果某个银行需要“点击某入口、设置查询条件、翻页、再提取表格”，可以在 `bank-agent.ps1` 里继续扩展步骤型任务。
