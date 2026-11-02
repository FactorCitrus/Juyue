# CookieJar 行为规格

对外入口（JS 桥接与登录流程依赖，签名不可变）：

- `shared`：进程内单例，落 `UserDefaults.standard`。
- `lastWrittenHostKey`：最近一次 `setCookies` 落到的 host key；`resetLastWrite()` 清空。
- `cookieString(for:)`：返回该 host 的 `name=value; name2=value2`，按名字升序；无记录返回空串。
- `setCookies(_:for:)`：合并写入；`name=` 空值删除该名字；出现 `Max-Age=0` 清空该 host。
- `value(for:name:)`：取单个 cookie；不存在返回 nil。
- `remove(for:)` / `removeAll()`：删除该 host / 全部。

host 归一：去掉 scheme、userinfo、path/query/fragment、端口与末尾空白，统一小写；IPv6 字面量去掉方括号。空输入返回空串，所有读写对空 host 直接返回。

属性名（path/domain/expires/max-age/samesite/secure/httponly/version/priority）不当作 cookie 名保存。

持久化：`[host: [name: value]]` 编码成 JSON。首次启动若发现旧版字符串字典，解析后迁移到新键并删除旧键；新键为空时不写盘。
