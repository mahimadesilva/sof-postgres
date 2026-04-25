import ballerina/test;

// ---------------------------------------------------------------------------
// testRepeatSimpleSinglePath
// ---------------------------------------------------------------------------

@test:Config {}
function testRepeatSimpleSinglePath() returns error? {
    // repeat: ["item"] with a column directly on the repeat select.
    // Expected: WITH RECURSIVE repeat_0 with anchor + one recursive member,
    // INNER JOIN on ctid, and linkId column sourcing from repeat_0.item_json.
    json viewDef = {
        "resource": "Questionnaire",
        "status": "active",
        "select": [{
            "repeat": ["item"],
            "column": [{"name": "linkId", "path": "linkId"}]
        }]
    };

    string result = check generateQuery(viewDef, defaultCtx());

    test:assertTrue(result.startsWith("WITH RECURSIVE repeat_0 AS ("),
        "Expected WITH RECURSIVE prefix");
    test:assertTrue(
        result.includes("CROSS JOIN LATERAL jsonb_array_elements(r.resource->'item') AS anchor(value)"),
        "Expected anchor LATERAL JOIN on 'item'");
    test:assertTrue(
        result.includes("CROSS JOIN LATERAL jsonb_array_elements(cte.item_json->'item') AS child_0(value)"),
        "Expected recursive LATERAL JOIN traversing item");
    test:assertTrue(
        result.includes("INNER JOIN repeat_0 ON repeat_0.resource_id = r.ctid"),
        "Expected INNER JOIN on ctid");
    test:assertTrue(
        result.includes("jsonb_extract_path_text(repeat_0.item_json::jsonb, 'linkId') AS \"linkId\""),
        "Expected linkId column to source from repeat_0.item_json");
    test:assertTrue(result.includes("WHERE r.resource_type = 'Questionnaire'"),
        "Expected resource_type filter");
}

// ---------------------------------------------------------------------------
// testRepeatMultiplePaths
// ---------------------------------------------------------------------------

@test:Config {}
function testRepeatMultiplePaths() returns error? {
    // repeat: ["item", "answer.item"] — anchor uses only the first path,
    // recursive member unions both paths with nested LATERAL JOINs for answer.item.
    json viewDef = {
        "resource": "Questionnaire",
        "status": "active",
        "select": [{
            "repeat": ["item", "answer.item"],
            "column": [{"name": "linkId", "path": "linkId"}]
        }]
    };

    string result = check generateQuery(viewDef, defaultCtx());

    test:assertTrue(
        result.includes("jsonb_array_elements(r.resource->'item') AS anchor(value)"),
        "Anchor must use first path ('item')");
    test:assertFalse(
        result.includes("jsonb_array_elements(r.resource->'answer'"),
        "Anchor must NOT use 'answer.item' path");
    // Multi-path: CTE is referenced exactly once; all paths combined inside a
    // CROSS JOIN LATERAL subquery to satisfy PostgreSQL's constraint.
    test:assertTrue(
        result.includes("CROSS JOIN LATERAL ("),
        "Multi-path recursive term must use a CROSS JOIN LATERAL subquery");
    test:assertTrue(
        result.includes(") AS paths"),
        "LATERAL subquery must be aliased as 'paths'");
    test:assertTrue(
        result.includes("jsonb_array_elements(cte.item_json->'item') AS path_0"),
        "Path 0 ('item') must appear inside the LATERAL subquery");
    test:assertTrue(
        result.includes("jsonb_array_elements(cte.item_json->'answer') AS path_1_0"),
        "Path 1 first segment ('answer') must appear inside the LATERAL subquery");
    test:assertTrue(
        result.includes("jsonb_array_elements(path_1_0.value->'item') AS path_1_1"),
        "Path 1 second segment ('item') must chain from path_1_0");
    test:assertEquals(countOccurrences(result, "UNION ALL"), 2,
        "Expected 2 UNION ALL: one at CTE body level, one inside the LATERAL subquery");
}

// ---------------------------------------------------------------------------
// testRepeatWithColumnFromOuterResource
// ---------------------------------------------------------------------------

@test:Config {}
function testRepeatWithColumnFromOuterResource() returns error? {
    // One plain select (id from outer resource) and one repeat select (linkId
    // from repeated items). Columns should use the correct contexts.
    json viewDef = {
        "resource": "Questionnaire",
        "status": "active",
        "select": [
            {"column": [{"name": "id", "path": "id"}]},
            {"repeat": ["item"], "column": [{"name": "linkId", "path": "linkId"}]}
        ]
    };

    string result = check generateQuery(viewDef, defaultCtx());

    test:assertTrue(
        result.includes("jsonb_extract_path_text(r.resource, 'id') AS \"id\""),
        "id column should source from outer resource");
    test:assertTrue(
        result.includes("jsonb_extract_path_text(repeat_0.item_json::jsonb, 'linkId') AS \"linkId\""),
        "linkId column should source from the repeat CTE");
    test:assertTrue(
        result.includes("INNER JOIN repeat_0 ON repeat_0.resource_id = r.ctid"),
        "Expected INNER JOIN on CTE");
}

// ---------------------------------------------------------------------------
// testRepeatWithNestedForEach
// ---------------------------------------------------------------------------

@test:Config {}
function testRepeatWithNestedForEach() returns error? {
    // forEach nested inside a repeat: the forEach LATERAL JOIN must source from
    // the CTE's item_json (not r.resource).
    json viewDef = {
        "resource": "Questionnaire",
        "status": "active",
        "select": [{
            "repeat": ["item"],
            "select": [{
                "forEach": "answerOption",
                "column": [{"name": "valueString", "path": "valueString"}]
            }]
        }]
    };

    string result = check generateQuery(viewDef, defaultCtx());

    test:assertTrue(result.startsWith("WITH RECURSIVE repeat_0 AS ("),
        "Expected WITH RECURSIVE prefix");
    test:assertTrue(
        result.includes("INNER JOIN repeat_0 ON repeat_0.resource_id = r.ctid"),
        "Expected INNER JOIN on CTE");
    test:assertTrue(
        result.includes("CROSS JOIN LATERAL jsonb_array_elements(repeat_0.item_json->'answerOption') AS forEach_0(value)"),
        "Nested forEach must source from repeat_0.item_json");
    test:assertFalse(
        result.includes("jsonb_array_elements(r.resource->'answerOption')"),
        "Nested forEach must NOT source from r.resource");
    test:assertTrue(
        result.includes("jsonb_extract_path_text(forEach_0.value::jsonb, 'valueString') AS \"valueString\""),
        "valueString column should use the forEach context");
}

// ---------------------------------------------------------------------------
// testRepeatWithUnionAll
// ---------------------------------------------------------------------------

@test:Config {}
function testRepeatWithUnionAll() returns error? {
    // Two unionAll branches: one with repeat, one plain. Each combination
    // generates its own SELECT but the repeat CTE is hoisted once at the top.
    json viewDef = {
        "resource": "Questionnaire",
        "status": "active",
        "select": [{
            "unionAll": [
                {"repeat": ["item"], "column": [{"name": "x", "path": "linkId"}]},
                {"column": [{"name": "x", "path": "id"}]}
            ]
        }]
    };

    string result = check generateQuery(viewDef, defaultCtx());

    test:assertTrue(result.startsWith("WITH RECURSIVE repeat_0 AS ("),
        "Expected single WITH RECURSIVE prefix");
    test:assertEquals(countOccurrences(result, "WITH RECURSIVE"), 1,
        "WITH RECURSIVE must appear exactly once");
    test:assertTrue(
        result.includes("jsonb_extract_path_text(repeat_0.item_json::jsonb, 'linkId') AS \"x\""),
        "Repeat branch must reference the CTE");
    test:assertTrue(
        result.includes("jsonb_extract_path_text(r.resource, 'id') AS \"x\""),
        "Plain branch must reference r.resource directly");
    // Combinations are joined by UNION ALL at the outermost level; plus the
    // internal UNION ALL inside the CTE body.
    test:assertTrue(countOccurrences(result, "UNION ALL") >= 2,
        "Expected at least 2 UNION ALL occurrences");
}

// ---------------------------------------------------------------------------
// testRepeatPrecedenceOverForEach
// ---------------------------------------------------------------------------

@test:Config {}
function testRepeatPrecedenceOverForEach() returns error? {
    // Combination has both a repeat select and a sibling forEach select.
    // Repeat takes precedence: the CTE is emitted, and the sibling forEach
    // becomes a regular LATERAL JOIN sourcing from r.resource.
    json viewDef = {
        "resource": "Questionnaire",
        "status": "active",
        "select": [
            {"repeat": ["item"], "column": [{"name": "linkId", "path": "linkId"}]},
            {"forEach": "name", "column": [{"name": "family", "path": "family"}]}
        ]
    };

    string result = check generateQuery(viewDef, defaultCtx());

    test:assertTrue(result.startsWith("WITH RECURSIVE repeat_0 AS ("),
        "Repeat must take precedence and emit the CTE");
    test:assertTrue(
        result.includes("INNER JOIN repeat_0 ON repeat_0.resource_id = r.ctid"),
        "Expected INNER JOIN on CTE");
    test:assertTrue(
        result.includes("CROSS JOIN LATERAL jsonb_array_elements(r.resource->'name') AS forEach_0(value)"),
        "Sibling forEach must source from r.resource");
    test:assertTrue(
        result.includes("jsonb_extract_path_text(repeat_0.item_json::jsonb, 'linkId') AS \"linkId\""),
        "linkId column should use repeat context");
    test:assertTrue(
        result.includes("jsonb_extract_path_text(forEach_0.value::jsonb, 'family') AS \"family\""),
        "family column should use forEach context");
}
