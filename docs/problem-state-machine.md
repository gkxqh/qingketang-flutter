# 随堂习题状态机

## 题目、作答与草稿

```mermaid
flowchart TD
    E[embeddedOnly<br/>课件预埋] -->|unlockproblem / problemon| O[publishedActive<br/>已发布]
    O -->|dt + limit 到期| X[overdue<br/>已超时]
    X -->|probleminfo / extendtime| O
    O -->|teacher close event| C[teacherClosed<br/>老师收题]
    X -->|teacher close event| C
    C -->|extendtime| O
    E --> L[lessonEnded]
    O --> L
    X --> L
    C --> L

    U[unknown] --> N[unanswered]
    N -->|HTTP code 0| M[submittedByMe]
    N -->|HTTP code 50028| A[answeredElsewhere]

    D0[absent] -->|select or type| D1[dirty]
    D1 -->|explicit save| D2[saved snapshot]
    D2 -->|edit again| D1
    D1 -->|clear| D0
    D2 -->|clear / success / 50028| D0
```

`dirty` 只能用于恢复编辑内容，不能触发自动提交。自动提交永远读取 `saved snapshot`。

## 提交任务

```mermaid
flowchart LR
    W[waitingPublish] -->|明确发布证据| S[scheduled]
    S -->|dueAt + owner lease| B[submitting]
    B -->|code 0| OK[succeeded]
    B -->|50028| AE[alreadyAnswered]
    B -->|closed before retry| RR[retryRequired]
    RR -->|allowOvertime| B
    B -->|network / ambiguous| UO[unknownOutcome]
    UO -->|one idempotent recheck| B
    B -->|temporary server error| RF[retryableFailed]
    RF -->|bounded retry| B
    B -->|auth expired| AU[authBlocked]
    W -->|teacher close| CC[canceledByClose]
    S -->|teacher close| CC
    W -->|clear preselection| CM[canceledByManual]
    S -->|manual submit wins| CM
```

## 前后台所有权

```mermaid
sequenceDiagram
    participant UI as Foreground
    participant Store as Durable Store
    participant BG as Background

    UI->>Store: persist scheduled jobs
    UI->>UI: cancel foreground timers and close socket
    UI->>Store: release foreground lease
    UI->>BG: start service
    BG->>Store: acquire background lease
    BG->>BG: hello + historical baseline
    BG->>Store: promote only waitingPublish jobs

    UI->>BG: resume requests stop
    BG->>Store: finish in-flight result, release lease
    UI->>Store: acquire new foreground lease
    UI->>UI: reconnect socket and resume sweeps
```

## 不变量

1. 历史时间线和初次 `hello` 不得仅凭草稿创建自动提交任务。
2. 自动提交只读取用户明确保存的不可变答案快照。
3. 同一课堂同一时刻只有一个运行所有者。
4. 手动提交和自动提交共用同一题的任务锁。
5. 收题在请求发出前取消任务；已发出的请求等待明确结果。
6. 网络结果未知时只做有限次幂等复核，`50028` 是最终去重信号。
7. 登录失效时保留草稿和任务，但立即停止所有提交与重连。
