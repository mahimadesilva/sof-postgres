import ballerina/test;

// ---------------------------------------------------------------------------
// testForEachSimpleColumnSQL
// ---------------------------------------------------------------------------

@test:Config {}
function testForEachSimpleColumnSQL() returns error? {
    // forEach: "name" with a single column → CROSS JOIN LATERAL on 'name' array,
    // column expression uses forEach_0.value as iteration context.
    ViewDefinitionSelect sel = {
        forEach: "name",
        column: [{name: "family", path: "family"}]
    };
    ViewDefinition viewDef = {
        'resource: "Patient",
        'select: [sel]
    };

    string result = check generateQuery(viewDef, defaultCtx());

    test:assertTrue(
        result.includes("CROSS JOIN LATERAL jsonb_array_elements(r.resource->'name') AS forEach_0(value)"),
        "Expected CROSS JOIN LATERAL on 'name'"
    );
    test:assertTrue(
        result.includes("jsonb_extract_path_text(forEach_0.value::jsonb, 'family') AS \"family\""),
        "Expected column expression using forEach_0.value"
    );
    test:assertTrue(result.includes("WHERE r.resource_type = 'Patient'"));
}

// ---------------------------------------------------------------------------
// testForEachOrNullSQL
// ---------------------------------------------------------------------------

@test:Config {}
function testForEachOrNullSQL() returns error? {
    // forEachOrNull: "name" → LEFT JOIN LATERAL … ON TRUE
    ViewDefinitionSelect sel = {
        forEachOrNull: "name",
        column: [{name: "family", path: "family"}]
    };
    ViewDefinition viewDef = {
        'resource: "Patient",
        'select: [sel]
    };

    string result = check generateQuery(viewDef, defaultCtx());

    test:assertTrue(
        result.includes("LEFT JOIN LATERAL jsonb_array_elements(r.resource->'name') AS forEach_0(value) ON TRUE"),
        "Expected LEFT JOIN LATERAL … ON TRUE for forEachOrNull"
    );
    test:assertFalse(result.includes("CROSS JOIN LATERAL"), "forEachOrNull must not produce CROSS JOIN");
}

// ---------------------------------------------------------------------------
// testForEachWithNonForEachColumn
// ---------------------------------------------------------------------------

@test:Config {}
function testForEachWithNonForEachColumn() returns error? {
    // Two selects: one plain (id column), one forEach (family column).
    // Both columns should appear in SELECT; only one LATERAL JOIN should be present.
    ViewDefinitionSelect idSel = {
        column: [{name: "id", path: "id"}]
    };
    ViewDefinitionSelect nameSel = {
        forEach: "name",
        column: [{name: "family", path: "family"}]
    };
    ViewDefinition viewDef = {
        'resource: "Patient",
        'select: [idSel, nameSel]
    };

    string result = check generateQuery(viewDef, defaultCtx());

    test:assertTrue(
        result.includes("jsonb_extract_path_text(r.resource, 'id') AS \"id\""),
        "Expected plain id column from base context"
    );
    test:assertTrue(
        result.includes("jsonb_extract_path_text(forEach_0.value::jsonb, 'family') AS \"family\""),
        "Expected family column from forEach context"
    );
    test:assertTrue(result.includes("CROSS JOIN LATERAL"), "Expected LATERAL JOIN for forEach select");
    test:assertEquals(countOccurrences(result, "CROSS JOIN LATERAL"), 1, "Exactly one LATERAL JOIN expected");
}

// ---------------------------------------------------------------------------
// testForEachNestedInNonForEach
// ---------------------------------------------------------------------------

@test:Config {}
function testForEachNestedInNonForEach() returns error? {
    // forEach is nested inside a non-forEach select's 'select' array.
    // The outer select contributes the id column directly; the inner forEach select
    // contributes the family column via a LATERAL JOIN.
    ViewDefinitionSelect inner = {
        forEach: "name",
        column: [{name: "family", path: "family"}]
    };
    ViewDefinitionSelect outerSel = {
        column: [{name: "id", path: "id"}],
        'select: [inner]
    };
    ViewDefinition viewDef = {
        'resource: "Patient",
        'select: [outerSel]
    };

    string result = check generateQuery(viewDef, defaultCtx());

    test:assertTrue(result.includes("CROSS JOIN LATERAL"), "Expected LATERAL JOIN for nested forEach");
    test:assertTrue(result.includes("\"family\""), "Expected family column from nested forEach");
    test:assertTrue(result.includes("\"id\""), "Expected id column from outer select");
}

// ---------------------------------------------------------------------------
// testForEachMultiSegmentPath
// ---------------------------------------------------------------------------

@test:Config {}
function testForEachMultiSegmentPath() returns error? {
    // forEach: "name.given" — two path segments require two nested LATERAL JOINs:
    //   forEach_0_nest0 iterates over 'name', forEach_0 iterates over 'given'.
    ViewDefinitionSelect sel = {
        forEach: "name.given",
        column: [{name: "givenName", path: "0"}]
    };
    ViewDefinition viewDef = {
        'resource: "Patient",
        'select: [sel]
    };

    string result = check generateQuery(viewDef, defaultCtx());

    test:assertTrue(
        result.includes("jsonb_array_elements(r.resource->'name') AS forEach_0_nest0(value)"),
        "Expected intermediate nest join for 'name'"
    );
    test:assertTrue(
        result.includes("jsonb_array_elements(forEach_0_nest0.value->'given') AS forEach_0(value)"),
        "Expected final join for 'given' sourced from nest0"
    );
    test:assertEquals(countOccurrences(result, "CROSS JOIN LATERAL"), 2, "Expected two LATERAL JOINs");
}

// ---------------------------------------------------------------------------
// testForEachGenerateQuery
// ---------------------------------------------------------------------------

@test:Config {}
function testForEachGenerateQuery() returns error? {
    // Smoke test: generateQuery must not error and must produce a LATERAL JOIN.
    ViewDefinition viewDef = {
        'resource: "Observation",
        'select: [
            {
                forEach: "component",
                column: [
                    {name: "code", path: "code"},
                    {name: "value", path: "valueString"}
                ]
            }
        ]
    };

    string result = check generateQuery(viewDef, defaultCtx());

    test:assertTrue(result.includes("LATERAL"), "Expected LATERAL keyword in forEach query");
    test:assertTrue(result.includes("WHERE r.resource_type = 'Observation'"));
    test:assertTrue(result.startsWith("SELECT"), "Expected query to start with SELECT");
}

// ---------------------------------------------------------------------------
// testForEachCustomTableAndColumn
// ---------------------------------------------------------------------------

@test:Config {}
function testForEachCustomTableAndColumn() returns error? {
    ViewDefinition viewDef = {
        'resource: "Observation",
        'select: [
            {
                forEach: "component",
                column: [{name: "code", path: "code"}]
            }
        ]
    };
    TranspilerContext ctx = {
        resourceAlias: "r",
        resourceColumn: "RESOURCE_JSON",
        tableName: "ObservationTable",
        filterByResourceType: false
    };

    string result = check generateQuery(viewDef, ctx);

    test:assertTrue(result.includes("FROM ObservationTable AS r"), "Expected ObservationTable in FROM clause");
    test:assertTrue(result.includes("RESOURCE_JSON"), "Expected RESOURCE_JSON in LATERAL JOIN source");
    test:assertFalse(result.includes("resource_type"), "resource_type must not appear for per-resource tables");
    test:assertTrue(result.includes("LATERAL"), "Expected LATERAL JOIN for forEach");
}
