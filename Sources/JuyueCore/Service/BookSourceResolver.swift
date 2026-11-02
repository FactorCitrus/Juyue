import Foundation

/// 书与书源的匹配。放在 Core 里是为了能被单元测试直接覆盖。
public enum BookSourceResolver {
    public static func find(book: Book, in sources: [BookSource]) -> BookSource? {
        let sources = sources.filter { !$0.bookSourceUrl.isEmpty }
        if book.origin == "local" || book.bookUrl.hasPrefix("file://")
            || book.bookUrl.hasPrefix("epub://") || book.bookUrl.hasPrefix("txt://") {
            return nil
        }

        if let exact = sources.first(where: { $0.bookSourceUrl == book.origin }) {
            return exact
        }

        let bookHost = URL(string: book.bookUrl)?.host ?? ""
        let patternCandidates = sources.filter { source in
            let sourceHost = URL(string: source.bookSourceUrl)?.host ?? ""
            if !bookHost.isEmpty, !sourceHost.isEmpty { return sourceHost == bookHost }
            return !book.originName.isEmpty && source.bookSourceName == book.originName
        }
        let patternMatches = patternCandidates.filter { $0.matchesBookUrl(book.bookUrl) }
        if let patterned = patternMatches.sorted(by: BookSource.selectionOrder).first {
            return patterned
        }

        if !book.originName.isEmpty,
           let named = sources.first(where: { $0.bookSourceName == book.originName }) {
            return named
        }

        let originURL = URL(string: book.origin)
        let urlHost = originURL?.host ?? bookHost
        if !urlHost.isEmpty {
            let candidates = sources.filter { candidate in
                guard URL(string: candidate.bookSourceUrl)?.host == urlHost else { return false }
                let sourceURL = candidate.bookSourceUrl
                let sourcePath = URL(string: sourceURL)?.path ?? ""
                let bookPath = URL(string: book.bookUrl)?.path ?? ""
                return book.bookUrl.hasPrefix(sourceURL)
                    || book.origin.hasPrefix(sourceURL)
                    || (sourcePath != "" && sourcePath != "/" && bookPath.hasPrefix(sourcePath))
            }
            if candidates.count == 1 { return candidates[0] }
            if candidates.count > 1 {
                return candidates.first(where: { $0.matchesBookUrl(book.bookUrl) })
            }
        }

        let fuzzy = sources.filter { s in
            book.origin.contains(s.bookSourceUrl)
                || s.bookSourceUrl.contains(book.origin)
                || book.bookUrl.hasPrefix(s.bookSourceUrl)
                || (!book.originName.isEmpty && s.bookSourceName.contains(book.originName))
                || (!book.originName.isEmpty && book.originName.contains(s.bookSourceName))
        }
        return fuzzy.count == 1 ? fuzzy[0] : nil
    }

    public static func find(searchBook item: SearchBook, in sources: [BookSource]) -> BookSource? {
        let sources = sources.filter { !$0.bookSourceUrl.isEmpty }
        if let exact = sources.first(where: { $0.bookSourceUrl == item.origin }) {
            return exact
        }
        let host = URL(string: item.bookUrl)?.host ?? ""
        let candidates = sources.filter { source in
            let sourceHost = URL(string: source.bookSourceUrl)?.host ?? ""
            if !host.isEmpty, !sourceHost.isEmpty { return host == sourceHost }
            return !item.originName.isEmpty && source.bookSourceName == item.originName
        }
        let matches = candidates.filter { $0.matchesBookUrl(item.bookUrl) }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { return matches.sorted(by: BookSource.selectionOrder).first }
        if !item.originName.isEmpty,
           let named = sources.first(where: { $0.bookSourceName == item.originName }) {
            return named
        }
        return nil
    }
}
