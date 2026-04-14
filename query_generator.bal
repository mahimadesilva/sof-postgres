// Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied. See the License for the
// specific language governing permissions and limitations
// under the License.

// ========================================
// SQL-ON-FHIR QUERY GENERATOR
// ========================================
// Generates PostgreSQL SELECT statements from ViewDefinition structures.
// Builds on top of expandCombinations() and the FHIRPath transpiler.

const string FHIR_RESOURCES_TABLE = "fhir_resources";

// ========================================
// PUBLIC API
// ========================================

# Generate a PostgreSQL query for a ViewDefinition.
#
# Expands all `unionAll` combinations and joins them with `UNION ALL`.
# Uses a default context with `resourceAlias = "r"`.
#
# + viewDef - The ViewDefinition to generate SQL for
# + resourceAlias - SQL alias for the resource table (default `"r"`)
# + return - The generated SQL string, or an error
public isolated function generateQuery(ViewDefinition viewDef, string resourceAlias = "r") returns string|error {
    TranspilerContext ctx = {resourceAlias, resourceColumn: "resource"};
    string[] statements = check generateAllSelectStatements(viewDef, ctx);
    return string:'join("\nUNION ALL\n", ...statements);
}

# Generate one SQL SELECT string per `SelectCombination`.
#
# + viewDef - The ViewDefinition
# + ctx - The transpiler context
# + return - One SQL string per combination, or an error
public isolated function generateAllSelectStatements(ViewDefinition viewDef, TranspilerContext ctx) returns string[]|error {
    SelectCombination[] combinations = expandCombinations(viewDef.'select);
    string[] statements = [];
    foreach SelectCombination combination in combinations {
        statements.push(check generateStatementForCombination(combination, viewDef, ctx));
    }
    return statements;
}

# Route a combination to the appropriate statement generator.
#
# Repeat takes precedence over forEach when both are present.
# forEach and repeat return an error (not yet implemented).
#
# + combination - The select combination to generate SQL for
# + viewDef - The ViewDefinition
# + ctx - The transpiler context
# + return - The generated SQL string, or an error
public isolated function generateStatementForCombination(
        SelectCombination combination,
        ViewDefinition viewDef,
        TranspilerContext ctx) returns string|error {

    if combinationHasRepeat(combination) {
        return error("generateRepeatStatement not yet implemented");
    } else if combinationHasForEach(combination) {
        return error("generateForEachStatement not yet implemented");
    }
    return generateSimpleStatement(combination, viewDef, ctx);
}

# Generate a simple SELECT statement (no forEach, no repeat).
#
# Assembles SELECT, FROM, and WHERE clauses from the combination.
#
# + combination - The select combination (must have no forEach/repeat)
# + viewDef - The ViewDefinition
# + ctx - The transpiler context
# + return - The generated SQL string, or an error
public isolated function generateSimpleStatement(
        SelectCombination combination,
        ViewDefinition viewDef,
        TranspilerContext ctx) returns string|error {

    string selectClause = check generateSimpleSelectClause(combination, ctx);
    string fromClause = generateFromClause(ctx.resourceAlias);
    string? whereClause = check buildWhereClause(viewDef.'resource, ctx.resourceAlias, viewDef.'where, ctx);

    string statement = selectClause + "\n" + fromClause;
    if whereClause is string {
        statement += "\n" + whereClause;
    }
    return statement;
}

// ========================================
// SELECT CLAUSE BUILDER
// ========================================

# Build the SELECT clause for a simple (non-forEach, non-repeat) combination.
#
# Iterates `combination.selects` and `combination.unionChoices` in parallel:
# - For each select element: collects columns recursively (skipping forEach selects).
# - For the chosen `unionAll` branch (if any): collects that branch's direct columns.
#
# + combination - The select combination
# + ctx - The transpiler context
# + return - The SELECT clause string (e.g. `SELECT\n  expr AS "name", …`), or an error
isolated function generateSimpleSelectClause(SelectCombination combination, TranspilerContext ctx) returns string|error {
    string[] columnParts = [];

    foreach int i in 0 ..< combination.selects.length() {
        ViewDefinitionSelect sel = combination.selects[i];
        int unionChoice = combination.unionChoices[i];

        // Collect columns from the select element itself (skips forEach selects).
        string[] cols = check collectSelectColumns(sel, ctx);
        foreach string c in cols {
            columnParts.push(c);
        }

        // Collect direct columns from the chosen unionAll branch (if any).
        ViewDefinitionSelect[]? unionAll = sel.unionAll;
        if unionAll is ViewDefinitionSelect[] && unionChoice >= 0 && unionChoice < unionAll.length() {
            ViewDefinitionSelect chosenBranch = unionAll[unionChoice];
            ViewDefinitionColumn[]? branchCols = chosenBranch.column;
            if branchCols is ViewDefinitionColumn[] {
                foreach ViewDefinitionColumn col in branchCols {
                    string expr = check generateColumnExpression(col, ctx);
                    columnParts.push(expr + " AS \"" + col.name + "\"");
                }
            }
        }
    }

    if columnParts.length() == 0 {
        return "SELECT *";
    }
    return "SELECT\n  " + string:'join(",\n  ", ...columnParts);
}

# Recursively collect `expr AS "name"` strings from a select element.
#
# Skips forEach/forEachOrNull selects (those are handled by `generateForEachStatement`).
# Recurses into nested `select` elements.
#
# + sel - The select element to collect columns from
# + ctx - The transpiler context
# + return - Column expression strings, or an error
isolated function collectSelectColumns(ViewDefinitionSelect sel, TranspilerContext ctx) returns string[]|error {
    if sel.forEach is string || sel.forEachOrNull is string {
        return [];
    }

    string[] parts = [];

    ViewDefinitionColumn[]? columns = sel.column;
    if columns is ViewDefinitionColumn[] {
        foreach ViewDefinitionColumn col in columns {
            string expr = check generateColumnExpression(col, ctx);
            parts.push(expr + " AS \"" + col.name + "\"");
        }
    }

    ViewDefinitionSelect[]? nested = sel.'select;
    if nested is ViewDefinitionSelect[] {
        foreach ViewDefinitionSelect nestedSel in nested {
            string[] nestedCols = check collectSelectColumns(nestedSel, ctx);
            foreach string c in nestedCols {
                parts.push(c);
            }
        }
    }

    return parts;
}

# Generate the SQL expression for a single column, with optional type cast.
#
# Calls `transpile()` on `col.path`, then wraps the result in a PostgreSQL
# cast if a FHIR type (or tag-based type override) is specified and the
# inferred PostgreSQL type is not `TEXT`.
#
# + col - The column definition
# + ctx - The transpiler context
# + return - The SQL expression string, or an error
isolated function generateColumnExpression(ViewDefinitionColumn col, TranspilerContext ctx) returns string|error {
    string expression = check transpile(col.path, ctx);

    string? fhirType = col.'type;
    if fhirType is () {
        return expression;
    }

    // Convert ViewDefinitionColumnTag[] to ColumnTag[] for inferSqlType.
    ColumnTag[]? colTags = ();
    ViewDefinitionColumnTag[]? rawTags = col.tag;
    if rawTags is ViewDefinitionColumnTag[] {
        colTags = from ViewDefinitionColumnTag t in rawTags select {name: t.name, value: t.value};
    }

    string pgType = inferSqlType(fhirType, colTags);
    return applyTypeCast(expression, pgType);
}

# Wrap a SQL expression in a PostgreSQL type cast.
#
# - `TEXT`: returned as-is (no cast needed).
# - `BOOLEAN`: uses `(expr)::BOOLEAN` syntax.
# - Other types: uses `CAST(expr AS type)` syntax.
#
# + expression - The SQL expression to cast
# + pgType - The PostgreSQL type string (from `inferSqlType`)
# + return - The cast expression
isolated function applyTypeCast(string expression, string pgType) returns string {
    if pgType == "TEXT" {
        return expression;
    }
    if pgType == "BOOLEAN" {
        return "(" + expression + ")::BOOLEAN";
    }
    return "CAST(" + expression + " AS " + pgType + ")";
}

// ========================================
// FROM / WHERE CLAUSE BUILDERS
// ========================================

# Generate the FROM clause.
#
# + resourceAlias - SQL alias for the resource table
# + return - The FROM clause string (e.g. `FROM fhir_resources AS r`)
isolated function generateFromClause(string resourceAlias) returns string {
    return "FROM " + FHIR_RESOURCES_TABLE + " AS " + resourceAlias;
}

# Build the WHERE clause combining resource type filter and view-level filters.
#
# Always includes `<alias>.resource_type = '<resource>'`.
# Appends each `ViewDefinitionWhere` condition by transpiling its FHIRPath expression.
#
# + resourceType - The FHIR resource type string (e.g. `"Patient"`)
# + resourceAlias - SQL alias for the resource table
# + whereConditions - Optional view-level filter conditions
# + ctx - The transpiler context
# + return - The WHERE clause string, or `()` if no conditions, or an error
isolated function buildWhereClause(
        string resourceType,
        string resourceAlias,
        ViewDefinitionWhere[]? whereConditions,
        TranspilerContext ctx) returns string?|error {

    string[] conditions = [];
    conditions.push(resourceAlias + ".resource_type = '" + resourceType + "'");

    if whereConditions is ViewDefinitionWhere[] {
        foreach ViewDefinitionWhere w in whereConditions {
            string condition = check transpile(w.path, ctx);
            conditions.push(condition);
        }
    }

    if conditions.length() == 0 {
        return ();
    }
    return "WHERE " + string:'join(" AND ", ...conditions);
}

// ========================================
// COMBINATION DETECTION HELPERS
// ========================================

# Check whether any select in the combination has a `forEach` or `forEachOrNull` directive.
#
# Also checks the chosen `unionAll` branch for each select.
#
# + combination - The select combination
# + return - `true` if any select (or chosen union branch) uses forEach/forEachOrNull
isolated function combinationHasForEach(SelectCombination combination) returns boolean {
    foreach int i in 0 ..< combination.selects.length() {
        ViewDefinitionSelect sel = combination.selects[i];
        if sel.forEach is string || sel.forEachOrNull is string {
            return true;
        }
        int unionChoice = combination.unionChoices[i];
        ViewDefinitionSelect[]? unionAll = sel.unionAll;
        if unionAll is ViewDefinitionSelect[] && unionChoice >= 0 && unionChoice < unionAll.length() {
            ViewDefinitionSelect branch = unionAll[unionChoice];
            if branch.forEach is string || branch.forEachOrNull is string {
                return true;
            }
        }
    }
    return false;
}

# Check whether any select in the combination has a `repeat` directive.
#
# Also checks the chosen `unionAll` branch for each select.
#
# + combination - The select combination
# + return - `true` if any select (or chosen union branch) uses repeat
isolated function combinationHasRepeat(SelectCombination combination) returns boolean {
    foreach int i in 0 ..< combination.selects.length() {
        ViewDefinitionSelect sel = combination.selects[i];
        string[]? rep = sel.repeat;
        if rep is string[] && rep.length() > 0 {
            return true;
        }
        int unionChoice = combination.unionChoices[i];
        ViewDefinitionSelect[]? unionAll = sel.unionAll;
        if unionAll is ViewDefinitionSelect[] && unionChoice >= 0 && unionChoice < unionAll.length() {
            ViewDefinitionSelect branch = unionAll[unionChoice];
            string[]? branchRep = branch.repeat;
            if branchRep is string[] && branchRep.length() > 0 {
                return true;
            }
        }
    }
    return false;
}
