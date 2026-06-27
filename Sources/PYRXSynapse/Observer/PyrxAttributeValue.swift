//
//  PyrxAttributeValue.swift
//  PYRXSynapse
//
//  Phase 9.2.1 PR-1 — Observer API.
//
//  Public type alias for the SDK's JSON value type, used in observer event
//  payloads (`PushReceivedEvent.pyrxAttributes`, `PushClickedEvent.pyrxAttributes`).
//
//  `JSONValue` has been public since 0.1.0 — it is the existing wire-shape
//  for `identify(traits:)` and `track(properties:)` payloads. We alias it
//  under a PYRX-prefixed name so observer-API consumers (apps embedding
//  the SDK and consuming `PyrxEvent`) read the type as a Synapse-domain
//  concept rather than a generic JSON encoder type. Both spellings refer
//  to the same case set — call sites can use either interchangeably.
//
//  No new type, no new conformances — by-design — so existing callers of
//  `identify(traits: [String: JSONValue])` continue to compile and the
//  observer payloads stay round-trip-equal with the wire format.
//

import Foundation

/// Alias for `JSONValue` exposed under a Synapse-domain name.
///
/// Cases (inherited verbatim from `JSONValue`):
///   * `.null`
///   * `.bool(Bool)`
///   * `.int(Int64)`
///   * `.double(Double)`
///   * `.string(String)`
///   * `.array([PyrxAttributeValue])`
///   * `.object([String: PyrxAttributeValue])`
///
/// Used as the value type for observer payloads (`pyrxAttributes`) so
/// downstream analytics joins on the same JSON shape the wire carries.
public typealias PyrxAttributeValue = JSONValue
