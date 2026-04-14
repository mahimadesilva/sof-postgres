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

# Implementation-specific directive attached to a ViewDefinition column.
# Example: `{ name: "pg/type", value: "TEXT" }`
public type ViewDefinitionColumnTag record {|
    # Tag key, e.g. `"pg/type"` or `"ansi/type"`
    string name;
    # Tag value, e.g. `"TEXT"`
    string value;
|};

# A column in a SQL-on-FHIR ViewDefinition select element.
public type ViewDefinitionColumn record {|
    # Output column name in the generated SQL result set
    string name;
    # FHIRPath expression that extracts the column value
    string path;
    # Optional human-readable description
    string? description = ();
    # When `true`, the column may hold multiple values (JSON array)
    boolean? collection = ();
    # FHIR primitive type name (e.g. `"string"`, `"integer"`)
    string? 'type = ();
    # Implementation-specific tags (e.g. database type hints)
    ViewDefinitionColumnTag[]? tag = ();
|};

# A FHIRPath-based filter condition in a ViewDefinition select element.
public type ViewDefinitionWhere record {|
    # FHIRPath expression that must evaluate to true for a row to be included
    string path;
    # Optional human-readable description
    string? description = ();
|};

# A select element in a SQL-on-FHIR ViewDefinition.
# May contain columns, nested selects, iteration directives, union branches, and filters.
public type ViewDefinitionSelect record {|
    # Columns produced by this select element
    ViewDefinitionColumn[]? column = ();
    # Nested select elements
    ViewDefinitionSelect[]? 'select = ();
    # FHIRPath expression to iterate over; rows with no match are excluded
    string? forEach = ();
    # FHIRPath expression to iterate over; rows with no match produce a null column
    string? forEachOrNull = ();
    # FHIRPath expression(s) for recursive repeat traversal
    string[]? repeat = ();
    # Union branches. When non-empty, each branch produces a separate SELECT
    # statement combined with UNION ALL in the final query.
    ViewDefinitionSelect[]? unionAll = ();
    # Row-level filter conditions evaluated as FHIRPath expressions
    ViewDefinitionWhere[]? 'where = ();
|};

# The result of expanding a single union combination from a ViewDefinition.
# `selects` holds the select elements contributing to this combination.
# `unionChoices` holds the union branch index chosen for each select element
# (-1 means the select had no unionAll; >= 0 is the index into its unionAll array).
public type SelectCombination record {|
    # Select elements that contribute to this combination
    ViewDefinitionSelect[] selects;
    # Parallel array of union branch indices (-1 = no union chosen)
    int[] unionChoices;
|};
