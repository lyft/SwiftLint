//
//  DocumentationCommentRule.swift
//  SwiftLint
//
//  Created by Keith Smiley on 8/4/15.
//  Copyright (c) 2015 Realm. All rights reserved.
//

import SourceKittenFramework
import SwiftXPC

private enum ValidScope: String {
    case Public = "source.lang.swift.accessibility.public"
    case Internal = "source.lang.swift.accessibility.internal"
}

private struct ProtocolMember: Equatable {
    let name: String
    let type: SwiftDeclarationKind
}

private func ==(lhs: ProtocolMember, rhs: ProtocolMember) -> Bool {
    return lhs.type == rhs.type && lhs.name == rhs.name
}

public struct DocumentationCommentRule: Rule {
    private let cachePath: String?

    public init(cachePath: String? = nil) {
        self.cachePath = cachePath?.absolutePathRepresentation()
    }

    private func protocolsToPaths() -> [String: String] {
        if let cachePath = self.cachePath,
            let URL = NSURL(fileURLWithPath: cachePath),
            let data = NSData(contentsOfURL: URL),
            let json: AnyObject = NSJSONSerialization.JSONObjectWithData(data, options: nil, error: nil),
            let protocols = json as? [String: String]
        {
            return protocols
        }

        return [:]
    }

    public let identifier = "documentation_comments"

    public func validateFile(file: File) -> [StyleViolation] {
        return validateFile(file, dictionary: file.structure.dictionary)
    }

    private func protocolMembersFromInheritedType(type: String, fromPaths paths: [String: String]) -> [ProtocolMember] {
        if let path = paths[type],
            let file = File(path: path),
            let substructure = file.structure.dictionary["key.substructure"] as? XPCArray
        {
            let structure = self.structuresFromArray(substructure)
            return self.protocolsFromStructure(structure).flatMap { element in
                if let substructureArray = element["key.substructure"] as? XPCArray {
                    let substructure = self.structuresFromArray(substructureArray)
                    return substructure.flatMap { element in
                        if let name = element["key.name"] as? String,
                            let type = element["key.kind"] as? String,
                            let kind = SwiftDeclarationKind(rawValue: type)
                        {
                            return [ProtocolMember(name: name, type: kind)]
                        }

                        return []
                    }
                }

                return []
            }
        }

        return []
    }

    private func structuresFromArray(array: XPCArray) -> [XPCDictionary] {
        var structures = [XPCDictionary]()
        for element in array {
            if let dictionary = element as? XPCDictionary {
                structures.append(dictionary)
            }
        }

        return structures
    }

    private func protocolsFromStructure(structure: [XPCDictionary]) -> [XPCDictionary] {
        return structure.flatMap { element in
            if let kind = element["key.kind"] as? String,
                let type = SwiftDeclarationKind(rawValue: kind)
                where type == .Protocol
            {
                return [element]
            }

            return []
        }
    }

    public func validateFile(file: File, dictionary: XPCDictionary) -> [StyleViolation] {
        return (dictionary["key.substructure"] as? XPCArray ?? []).flatMap { element in
            let element: XPCDictionary! = element as? XPCDictionary
            if element == nil { return [] }

            if self.isTopLevelCommentableType(element["key.kind"]) &&
                (self.scopeNeedsComment(element["key.accessibility"]) ||
                    self.isExtension(element["key.kind"]))
            {
                let inheritedTypes = element["key.inheritedtypes"] as? XPCArray ?? []
                let typeNames = compact(inheritedTypes.map { $0 as? XPCDictionary }.map { $0?["key.name"] as? String })
                if self.inheritsFromBlacklist(typeNames) {
                    return []
                }

                let paths = self.protocolsToPaths()
                var excluded = [ProtocolMember]()
                for type in typeNames {
                    excluded.extend(self.protocolMembersFromInheritedType(type, fromPaths: paths))
                }

                var violations = [StyleViolation]()
                if self.isCommentableType(element["key.kind"]) &&
                    !self.attributesHasComment(element["key.attributes"] as? XPCArray),
                    let offset = element["key.offset"] as? Int64
                {
                    let location = Location(file: file, offset: Int(offset))
                    violations = [StyleViolation(type: .DocumentationComment,
                        location: location, reason: "Needs documentation comment")]
                }

                return violations + (element["key.substructure"] as? XPCArray ?? []).flatMap { subElement in
                    let subElement: XPCDictionary! = subElement as? XPCDictionary
                    if subElement == nil { return [] }

                    if self.scopeNeedsComment(subElement["key.accessibility"]) &&
                        self.shouldComment(subElement, excluded: excluded),
                        let offset = subElement["key.offset"] as? Int64
                    {
                        let location = Location(file: file, offset: Int(offset))
                        return [StyleViolation(type: .DocumentationComment,
                            location: location, reason: "Needs documentation comment")]
                    }

                    return []
                }
            }

            return []
        }
    }

    private func shouldComment(element: XPCDictionary, excluded: [ProtocolMember]) -> Bool {
        if !self.typeNeedsComment(element["key.kind"]) {
            return false
        }

        if let name = element["key.name"] as? String where self.isNameExcluded(name) {
            return false
        }

        let attributes = element["key.attributes"] as? XPCArray ?? []
        if self.attributesHasComment(attributes) {
            return false
        }

        if self.isOverride(attributes) {
            return false
        }

        if self.isIBOutlet(attributes) {
            return false
        }

        if self.isExcludedProtocolMember(element, excludedMembers: excluded) {
            return false
        }

        return true
    }

    private let blackListedRegexes = [
        "^CardIOPaymentViewControllerDelegate$",
        "^CLLocationManagerDelegate$",
        "^GMSMapViewDelegate$",
        "^UI\\w+(Delegate|DataSource)\\w*$",
        "^UISearchResultsUpdating$",
    ]

    private func inheritsFromBlacklist(inheritedTypes: [String]) -> Bool {
        for regexString in blackListedRegexes {
            let regex = NSRegularExpression(pattern: regexString, options: nil, error: nil)
            for type in inheritedTypes {
                let range = NSRange(location: 0, length: count(type))
                if regex?.firstMatchInString(type, options: nil, range: range) != nil {
                    return true
                }
            }
        }

        return false
    }

    private func isExcludedProtocolMember(attributes: XPCDictionary, excludedMembers: [ProtocolMember]) -> Bool {
        if let name = attributes["key.name"] as? String,
            let type = attributes["key.kind"] as? String,
            let kind = SwiftDeclarationKind(rawValue: type)
        {
            let memberType = ProtocolMember(name: name, type: kind)
            for excluded in excludedMembers {
                if excluded == memberType {
                    return true
                }
            }
        }

        return false
    }

    private func isNameExcluded(name: String) -> Bool {
        if name.hasPrefix("init") {
            return true
        } else if name == "deinit" {
            return true
        } else if name == "hashValue" {
            return true
        }

        return false
    }

    private func isOverride(attributes: XPCArray?) -> Bool {
        return self.attributesContainString(attributes, string: "source.decl.attribute.override")
    }

    private func isIBOutlet(attributes: XPCArray?) -> Bool {
        return self.attributesContainString(attributes, string: "source.decl.attribute.iboutlet")
    }

    private func attributesHasComment(attributes: XPCArray?) -> Bool {
        return self.attributesContainString(attributes, string: "source.decl.attribute.__raw_doc_comment")
    }

    private func attributesContainString(attributes: XPCArray?, string: String) -> Bool {
        for attribute in attributes ?? [] {
            if let dict = attribute as? XPCDictionary, let value = dict["key.attribute"] {
                if value == string {
                    return true
                }
            }
        }

        return false
    }

    private func scopeNeedsComment(scope: XPCRepresentable?) -> Bool {
        if let scope = scope as? String {
            return ValidScope(rawValue: scope) != nil
        }

        return false
    }

    private func isCommentableType(t: XPCRepresentable?) -> Bool {
        if let type = t as? String, let kind = SwiftDeclarationKind(rawValue: type) {
            switch kind {
            case .Class, .Extension, .Struct:
                return false
            default:
                return true
            }
        }

        return true
    }

    private func isTopLevelCommentableType(t: XPCRepresentable?) -> Bool {
        if let type = t as? String, let kind = SwiftDeclarationKind(rawValue: type) {
            switch kind {
            case .Class, .Enum, .Struct, .Extension, .Protocol, .VarGlobal, .FunctionFree, .Typealias:
                return true
            default:
                return false
            }
        }

        return false
    }

    private func isExtension(t: XPCRepresentable?) -> Bool {
        if let type = t as? String, let kind = SwiftDeclarationKind(rawValue: type) {
            switch kind {
            case .Extension:
                return true
            default:
                return false
            }
        }

        return false
    }

    private func typeNeedsComment(type: XPCRepresentable?) -> Bool {
        if let type = type as? String, let kind = SwiftDeclarationKind(rawValue: type) {
            switch kind {
            case .VarInstance, .VarStatic, .VarClass, .FunctionMethodClass, .FunctionMethodInstance, .FunctionMethodStatic, .FunctionSubscript, .Typealias:
                return true
            default:
                return false
            }
        }

        return false
    }

    public let example = RuleExample(
        ruleName: "Documentation Comment Rule",
        ruleDescription: "This rule checks if you have documented public and internal properties and classes",
        nonTriggeringExamples: [
            "// foo\npublic class Foo {\n// bar\nvar foo}\n",
            "// bar\npublic class Foo {}\n",
            "/*foo*/\nclass Foo {}\n",
            "// foo\ninternal class Foo {}\n",
            "// foo\ninternal var foo\n",
            "private class Foo {\nvar foo}\n",
            "private class Foo {\nprivate let foo}\n",
            "class Foo {}\n",
            "public class Foo {}\n",
            "extension Foo {}\n",
            "struct Foo {}\n",
            "extension Foo: UITextFieldDelegate { var Foo: String }\n",
            "struct Bar { Struct Foo {}}\n",
        ],
        triggeringExamples: [
            "extension Foo { var foo: String }\n",
            "var foo: String\n",
            "let Bar\n",
            "class Bar { class var Foo: String }\n",
            "struct Bar {\nstatic var foo: String\n}\n",
            "func == () {}\n",
        ]
    )
}