import Foundation

// ChatGPT OAuth初回登録のloopback listenerがブラウザへ返すHTTP responseを、固定文だけで組み立てるためのAPI。
// ソケット・ネットワーク通信・listener・ブラウザ・Keychain・保存は行わず、アプリ本体からもまだ呼び出さない。
//
// 入力は ChatGPTOAuthLoopbackResponseKind（関連値を持たないenum）だけにする。
// callbackのcode・state・error・request target・headerなど、外部から来た文字列は引数として受け取れないため、
// 本文やheaderへ反映させることが構造上できない。
//
// 組み立てる形:
// - status lineは "HTTP/1.1 <code> <reason>"。3xx（redirect）は返さず、Locationも付けない
// - 本文は種類ごとに固定の短い日本語のプレーンテキスト（UTF-8）
// - Content-Lengthは本文のUTF-8バイト数と一致する
// - Cache-Control: no-store / Referrer-Policy: no-referrer / X-Content-Type-Options: nosniff /
//   Content-Security-Policy: default-src 'none' / Connection: close を必ず付ける
// - headerの改行はCRLFのみで、response全体は maxResponseLength バイト以下
//
// 成功時の本文は「ブラウザがcallbackを受け取った」ことだけを伝え、サインイン完了とは書かない。
// tokenの交換・検証はこの後アプリ側で行うため、ここで完了と表示すると誤認させてしまう。

// 返すresponseの種類。関連値を持たせないことで、入力値を本文・headerへ流し込む経路を作らない
enum ChatGPTOAuthLoopbackResponseKind: CaseIterable, Equatable {
    // callback pathへのrequestを受け取った（サインイン完了ではない）。アプリへ戻る案内を出す
    case callbackReceived
    // callbackのrequestを受け取ったが、試行側で受理できなかった
    case callbackFailed
    // callback path以外（/favicon.icoなど）へのrequest
    case notFound
    // GET以外のmethod
    case methodNotAllowed
    // request headが上限を超えている
    case requestHeadTooLarge
}

enum ChatGPTOAuthLoopbackResponseBuilder {
    // response全体（status line・header・本文）の上限バイト数
    static let maxResponseLength = 1024

    /// - Parameter kind: 返すresponseの種類
    /// - Returns: socketへそのまま書き込めるHTTP/1.1 responseのバイト列
    static func response(for kind: ChatGPTOAuthLoopbackResponseKind) throws -> Data {
        let body = Data(bodyText(for: kind).utf8)

        // headerはすべて固定文字列。順序も固定にして、同じkindなら常に同じバイト列になるようにする
        var headers: [(name: String, value: String)] = [
            ("Content-Type", "text/plain; charset=utf-8"),
            // Content-Lengthは文字数ではなくUTF-8のバイト数（日本語は1文字3バイト）
            ("Content-Length", String(body.count)),
            ("Cache-Control", "no-store"),
            ("Referrer-Policy", "no-referrer"),
            ("X-Content-Type-Options", "nosniff"),
            ("Content-Security-Policy", "default-src 'none'"),
            ("Connection", "close"),
        ]
        // 405ではRFC 9110に従い、受け付けるmethodをAllowで示す
        if kind == .methodNotAllowed {
            headers.append(("Allow", "GET"))
        }

        // 改行はCRLFのみ。最後の空行（CRLF CRLF）でheadの終わりを示す
        var head = statusLine(for: kind) + "\r\n"
        for header in headers {
            head += "\(header.name): \(header.value)\r\n"
        }
        head += "\r\n"

        // headは固定のASCII文字列だけで作っているので、UTF-8変換してもASCIIのまま
        var data = Data(head.utf8)
        data.append(body)

        // 固定文なので通常は超えないが、文言変更で上限を超えた場合に気付けるよう確認する
        guard data.count <= maxResponseLength else {
            throw ChatGPTOAuthLoopbackResponseError.responseTooLarge
        }
        return data
    }

    // 種類ごとの固定status line。3xxは返さない
    private static func statusLine(for kind: ChatGPTOAuthLoopbackResponseKind) -> String {
        switch kind {
        case .callbackReceived:
            return "HTTP/1.1 200 OK"
        case .callbackFailed:
            return "HTTP/1.1 400 Bad Request"
        case .notFound:
            return "HTTP/1.1 404 Not Found"
        case .methodNotAllowed:
            return "HTTP/1.1 405 Method Not Allowed"
        case .requestHeadTooLarge:
            return "HTTP/1.1 431 Request Header Fields Too Large"
        }
    }

    // 種類ごとの固定本文（1行・改行なし）。
    // 200でも「受け取った」ことだけを伝え、サインイン完了とは書かない
    private static func bodyText(for kind: ChatGPTOAuthLoopbackResponseKind) -> String {
        switch kind {
        case .callbackReceived:
            return "認証結果を受け取りました。アプリへ戻って確認してください。"
        case .callbackFailed:
            return "認証結果を確認できませんでした。アプリへ戻ってやり直してください。"
        case .notFound:
            return "このページは見つかりません。"
        case .methodNotAllowed:
            return "このリクエスト方法には対応していません。"
        case .requestHeadTooLarge:
            return "リクエストが大きすぎるため処理できません。"
        }
    }
}

// エラーには入力値を含めない（関連値を持たせない）
enum ChatGPTOAuthLoopbackResponseError: Error, Equatable {
    // RED段階のstubであることを示していた値。テストが「stubのままではない」ことの確認に使うため残す
    case notImplemented
    // 組み立てたresponseが maxResponseLength を超えた
    case responseTooLarge
}
