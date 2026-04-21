import ballerina/test;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

# Default transpiler context used across tests (shared-table layout).
# + return - `TranspilerContext` with `resourceAlias = "r"`, `resourceColumn = "resource"`, `tableName = "fhir_resources"`
isolated function defaultCtx() returns TranspilerContext {
    return {resourceAlias: "r", resourceColumn: "resource", tableName: "fhir_resources"};
}

# Per-resource-type transpiler context for custom-schema tests.
# + resourceType - FHIR resource type (e.g. "Patient") — used to derive table name
# + return - `TranspilerContext` targeting `<ResourceType>Table` with `RESOURCE_JSON` column and no type filter
isolated function perResourceCtx(string resourceType) returns TranspilerContext {
    return {resourceAlias: "r", resourceColumn: "RESOURCE_JSON", tableName: resourceType + "Table", filterByResourceType: false};
}

# Minimal combination with no union choice (single select, unionChoice = -1).
# + sel - The single select element to wrap
# + return - `SelectCombination` with `selects = [sel]` and `unionChoices = [-1]`
isolated function simpleCombination(ViewDefinitionSelect sel) returns SelectCombination {
    return {selects: [sel], unionChoices: [-1]};
}

// ---------------------------------------------------------------------------
// generateSimpleStatement
// ---------------------------------------------------------------------------

@test:Config {}
function testSimpleSingleColumn() returns error? {
    ViewDefinitionSelect sel = {
        column: [{name: "id", path: "id"}]
    };
    ViewDefinition viewDef = {
        'resource: "Patient",
        'select: [sel]
    };

    string result = check generateSimpleStatement(simpleCombination(sel), viewDef, defaultCtx());

    string expected =
        "SELECT\n  jsonb_extract_path_text(r.resource, 'id') AS \"id\"\n"
        + "FROM fhir_resources AS r\n"
        + "WHERE r.resource_type = 'Patient'";
    test:assertEquals(result, expected);
}

@test:Config {}
function testSimpleMultipleColumns() returns error? {
    ViewDefinitionSelect sel = {
        column: [
            {name: "id", path: "id"},
            {name: "birthDate", path: "birthDate"}
        ]
    };
    ViewDefinition viewDef = {
        'resource: "Patient",
        'select: [sel]
    };

    string result = check generateSimpleStatement(simpleCombination(sel), viewDef, defaultCtx());

    string expected =
        "SELECT\n"
        + "  jsonb_extract_path_text(r.resource, 'id') AS \"id\",\n"
        + "  jsonb_extract_path_text(r.resource, 'birthDate') AS \"birthDate\"\n"
        + "FROM fhir_resources AS r\n"
        + "WHERE r.resource_type = 'Patient'";
    test:assertEquals(result, expected);
}

@test:Config {}
function testSimpleNestedSelect() returns error? {
    // Columns in a nested select should be included in the SELECT list.
    ViewDefinitionSelect inner = {
        column: [{name: "birthDate", path: "birthDate"}]
    };
    ViewDefinitionSelect outerSel = {
        column: [{name: "id", path: "id"}],
        'select: [inner]
    };
    ViewDefinition viewDef = {
        'resource: "Patient",
        'select: [outerSel]
    };

    string result = check generateSimpleStatement(simpleCombination(outerSel), viewDef, defaultCtx());

    string expected =
        "SELECT\n"
        + "  jsonb_extract_path_text(r.resource, 'id') AS \"id\",\n"
        + "  jsonb_extract_path_text(r.resource, 'birthDate') AS \"birthDate\"\n"
        + "FROM fhir_resources AS r\n"
        + "WHERE r.resource_type = 'Patient'";
    test:assertEquals(result, expected);
}

@test:Config {}
function testSimpleViewWhere() returns error? {
    // A view-level where condition should appear in the WHERE clause.
    ViewDefinitionSelect sel = {
        column: [{name: "id", path: "id"}]
    };
    ViewDefinition viewDef = {
        'resource: "Patient",
        'select: [sel],
        'where: [{path: "id = 'test-id'"}]
    };

    string result = check generateSimpleStatement(simpleCombination(sel), viewDef, defaultCtx());

    // The WHERE clause must contain the resource type filter AND the transpiled FHIRPath condition.
    test:assertTrue(result.includes("WHERE r.resource_type = 'Patient'"));
    test:assertTrue(result.includes("(jsonb_extract_path_text(r.resource, 'id') = 'test-id')"));
}

@test:Config {}
function testSimpleNoColumns() returns error? {
    // A combination with no columns should fall back to SELECT *.
    ViewDefinitionSelect sel = {};
    ViewDefinition viewDef = {'resource: "Patient", 'select: [sel]};

    string result = check generateSimpleStatement(simpleCombination(sel), viewDef, defaultCtx());

    test:assertTrue(result.startsWith("SELECT *"));
}

// ---------------------------------------------------------------------------
// Type casting
// ---------------------------------------------------------------------------

@test:Config {}
function testTypecastInteger() returns error? {
    ViewDefinitionSelect sel = {
        column: [{name: "count", path: "someInt", 'type: "integer"}]
    };
    ViewDefinition viewDef = {'resource: "Patient", 'select: [sel]};

    string result = check generateSimpleStatement(simpleCombination(sel), viewDef, defaultCtx());

    test:assertTrue(result.includes("CAST(jsonb_extract_path_text(r.resource, 'someInt') AS INTEGER) AS \"count\""));
}

@test:Config {}
function testTypecastBoolean() returns error? {
    ViewDefinitionSelect sel = {
        column: [{name: "active", path: "active", 'type: "boolean"}]
    };
    ViewDefinition viewDef = {'resource: "Patient", 'select: [sel]};

    string result = check generateSimpleStatement(simpleCombination(sel), viewDef, defaultCtx());

    test:assertTrue(result.includes("(jsonb_extract_path_text(r.resource, 'active'))::BOOLEAN AS \"active\""));
}

@test:Config {}
function testTypecastString() returns error? {
    // FHIR "string" maps to PostgreSQL TEXT — no cast should be applied.
    ViewDefinitionSelect sel = {
        column: [{name: "gender", path: "gender", 'type: "string"}]
    };
    ViewDefinition viewDef = {'resource: "Patient", 'select: [sel]};

    string result = check generateSimpleStatement(simpleCombination(sel), viewDef, defaultCtx());

    // No CAST wrapper — raw expression only.
    test:assertTrue(result.includes("jsonb_extract_path_text(r.resource, 'gender') AS \"gender\""));
    test:assertFalse(result.includes("CAST("));
}

// ---------------------------------------------------------------------------
// generateQuery — UNION ALL
// ---------------------------------------------------------------------------

@test:Config {}
function testUnionAllCombinations() returns error? {
    // One select with two unionAll branches → two SQL statements joined by UNION ALL.
    ViewDefinitionSelect sel = {
        unionAll: [
            {column: [{name: "id", path: "id"}]},
            {column: [{name: "id", path: "id"}]}
        ]
    };
    ViewDefinition viewDef = {'resource: "Patient", 'select: [sel]};

    string result = check generateQuery(viewDef, defaultCtx());

    test:assertTrue(result.includes("\nUNION ALL\n"));
    // Both halves should be SELECT statements against the same table.
    int selectCount = countOccurrences(result, "SELECT\n");
    test:assertEquals(selectCount, 2);
}

@test:Config {}
function testSingleCombinationNoUnionAll() returns error? {
    // Two selects without unionAll → one combination, no UNION ALL in output.
    ViewDefinition viewDef = {
        'resource: "Observation",
        'select: [
            {column: [{name: "id", path: "id"}]},
            {column: [{name: "status", path: "status"}]}
        ]
    };

    string result = check generateQuery(viewDef, defaultCtx());

    test:assertFalse(result.includes("UNION ALL"));
    test:assertTrue(result.includes("SELECT\n"));
    test:assertTrue(result.includes("WHERE r.resource_type = 'Observation'"));
}

// ---------------------------------------------------------------------------
// Custom schema — per-resource-type table + RESOURCE_JSON column
// ---------------------------------------------------------------------------

@test:Config {}
function testCustomResourceColumn() returns error? {
    ViewDefinitionSelect sel = {
        column: [{name: "id", path: "id"}]
    };
    ViewDefinition viewDef = {'resource: "Patient", 'select: [sel]};
    TranspilerContext ctx = {resourceAlias: "r", resourceColumn: "RESOURCE_JSON", tableName: "fhir_resources"};

    string result = check generateSimpleStatement(simpleCombination(sel), viewDef, ctx);

    test:assertTrue(result.includes("r.RESOURCE_JSON"), "Expected RESOURCE_JSON column in SQL");
    test:assertFalse(result.includes("r.resource,") || result.includes("r.resource'"), "Default column must not appear");
}

@test:Config {}
function testCustomTableName() returns error? {
    ViewDefinitionSelect sel = {
        column: [{name: "id", path: "id"}]
    };
    ViewDefinition viewDef = {'resource: "Patient", 'select: [sel]};
    TranspilerContext ctx = {resourceAlias: "r", resourceColumn: "resource", tableName: "PatientTable"};

    string result = check generateSimpleStatement(simpleCombination(sel), viewDef, ctx);

    test:assertTrue(result.includes("FROM PatientTable AS r"), "Expected PatientTable in FROM clause");
}

@test:Config {}
function testPerResourceTableNoTypeFilter() returns error? {
    ViewDefinitionSelect sel = {
        column: [
            {name: "id", path: "id"},
            {name: "birthDate", path: "birthDate"}
        ]
    };
    ViewDefinition viewDef = {'resource: "Patient", 'select: [sel]};

    string result = check generateQuery(viewDef, perResourceCtx("Patient"));

    test:assertTrue(result.includes("FROM PatientTable AS r"), "Expected PatientTable in FROM clause");
    test:assertTrue(result.includes("RESOURCE_JSON"), "Expected RESOURCE_JSON column in expressions");
    test:assertFalse(result.includes("resource_type"), "resource_type filter must not appear for per-resource tables");
}

@test:Config {}
function testCustomSchemaWithWhere() returns error? {
    ViewDefinitionSelect sel = {
        column: [{name: "id", path: "id"}]
    };
    ViewDefinition viewDef = {
        'resource: "Patient",
        'select: [sel],
        'where: [{path: "active = true"}]
    };

    string result = check generateQuery(viewDef, perResourceCtx("Patient"));

    test:assertTrue(result.includes("FROM PatientTable AS r"), "Expected PatientTable");
    test:assertFalse(result.includes("resource_type"), "resource_type must not appear");
    test:assertTrue(result.includes("WHERE"), "Expected WHERE clause for the view-level filter");
    test:assertTrue(result.includes("active"), "Expected transpiled where condition");
}

// ---------------------------------------------------------------------------
// combinationHasForEach / combinationHasRepeat
// ---------------------------------------------------------------------------

@test:Config {}
function testCombinationHasForEach() {
    SelectCombination withForEach = {
        selects: [{forEach: "name"}],
        unionChoices: [-1]
    };
    SelectCombination withoutForEach = {
        selects: [{column: [{name: "id", path: "id"}]}],
        unionChoices: [-1]
    };

    test:assertTrue(combinationHasForEach(withForEach));
    test:assertFalse(combinationHasForEach(withoutForEach));
}

@test:Config {}
function testCombinationHasRepeat() {
    SelectCombination withRepeat = {
        selects: [{repeat: ["item"]}],
        unionChoices: [-1]
    };
    SelectCombination withoutRepeat = {
        selects: [{column: [{name: "id", path: "id"}]}],
        unionChoices: [-1]
    };

    test:assertTrue(combinationHasRepeat(withRepeat));
    test:assertFalse(combinationHasRepeat(withoutRepeat));
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

# Count the number of non-overlapping occurrences of `sub` in `str`.
# + str - The string to search within
# + sub - The substring to search for
# + return - Number of non-overlapping occurrences
isolated function countOccurrences(string str, string sub) returns int {
    int count = 0;
    int idx = 0;
    while idx <= str.length() - sub.length() {
        if str.substring(idx, idx + sub.length()) == sub {
            count += 1;
            idx += sub.length();
        } else {
            idx += 1;
        }
    }
    return count;
}
