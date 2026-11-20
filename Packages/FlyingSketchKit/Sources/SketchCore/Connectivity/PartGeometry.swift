/// Part-local mm (top-left origin) -> world mm. Single source of truth for part rotation
/// (`PartInstance.worldPoint` and hit-testing share it): rotate `p - size/2` by `rotation` radians
/// clockwise, then add `center`.
public func localToWorld(_ p: Vec2, instance: PartInstance, definition: PartDefinition) -> Vec2 {
    instance.worldPoint(p, in: definition)
}

/// World position of every connector. Legged connectors use `legEnds[id]`, else the rotated default end.
public func connectorPositions(_ instance: PartInstance, _ def: PartDefinition) -> [String: Vec2] {
    var result: [String: Vec2] = [:]
    result.reserveCapacity(def.connectors.count)
    for c in def.connectors {
        if let leg = c.leg {
            result[c.id] = instance.legEnds[c.id] ?? localToWorld(leg.defaultEnd, instance: instance, definition: def)
        } else {
            result[c.id] = localToWorld(c.position, instance: instance, definition: def)
        }
    }
    return result
}
