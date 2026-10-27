//
//  Array+FileSystem.FileItem.swift
//  CodeEdit
//
//  Created by Matthijs Eikelenboom on 07/02/2023.
//

import Foundation

extension Array where Element == URL {

    /// Sorts the elements in alphabetical order.
    /// - Parameter foldersOnTop: if set to `true` folders will always be on top of files.
    /// - Returns: A sorted array of `URL`
    func sortItems(foldersOnTop: Bool) -> [URL] {
        guard count > 1 else { return self }

        // 预取排序键：`resourceValues` 是磁盘 stat，写在比较器里会被排序调用
        // O(n log n) 次——一个上千项的目录就是上万次系统调用。
        // 预取后每个元素只查一次，并同时缓存 lastPathComponent。
        let keyed = map { url -> (url: URL, isDirectory: Bool, name: String) in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return (url, isDirectory, url.lastPathComponent)
        }

        return keyed.sorted { lhs, rhs in
            if foldersOnTop, lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return compareNaturally(lhs.name, rhs.name)
        }.map(\.url)
    }

    /// Compare two strings using natural sorting.
    /// - Parameters:
    ///   - lhs: The left-hand string.
    ///   - rhs: The right-hand string.
    /// - Returns: `true` if `lhs` should be ordered before `rhs`.
    private func compareNaturally(_ lhs: String, _ rhs: String) -> Bool {
        let lhsComponents = lhs.components(separatedBy: CharacterSet.decimalDigits.inverted)
        let rhsComponents = rhs.components(separatedBy: CharacterSet.decimalDigits.inverted)

        for (lhsPart, rhsPart) in zip(lhsComponents, rhsComponents) where lhsPart != rhsPart {
            if let lhsNum = Int(lhsPart), let rhsNum = Int(rhsPart) {
                return lhsNum < rhsNum
            } else {
                return lhsPart < rhsPart
            }
        }

        return lhs < rhs
    }
}

extension Array where Element: Hashable {

    /// Checks the difference between two given items.
    /// - Parameter other: Other element
    /// - Returns: symmetricDifference
    func difference(from other: [Element]) -> [Element] {
        let thisSet = Set(self)
        let otherSet = Set(other)
        return Array(thisSet.symmetricDifference(otherSet))
    }

}
