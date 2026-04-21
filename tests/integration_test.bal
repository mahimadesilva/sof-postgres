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

// Integration test: connects to a real PostgreSQL instance, generates a
// ViewDefinition query, creates a view from it, and verifies results.
//
// Prerequisites:
//   - A running PostgreSQL instance with credentials in tests/Config.toml
//   - The generated SQL is asserted to match the expected string; the same
//     SQL is executed via a compile-time template literal (Ballerina's sql
//     module does not permit constructing ParameterizedQuery from runtime strings).

import ballerinax/postgresql;
import ballerinax/postgresql.driver as _;
import ballerina/sql;
import ballerina/test;

configurable string host = "localhost";
configurable int port = 5432;
configurable string database = "postgres";
configurable string username = "postgres";
configurable string password = "postgres";

// Module-level record type for view rows.
type PatientRow record {|
    string id;
    string birthDate;
|};

// Expected SQL produced by generateQuery for the test ViewDefinition.
// Table: PatientTable (PostgreSQL normalises unquoted names to lowercase).
// Column: resource_json (lowercase avoids quoting requirements in generated SQL).
// Traced manually from the transpiler to lock the contract between the
// SQL generator and the database test.
final string EXPECTED_PATIENT_VIEW_SQL =
    "SELECT\n"
    + "  jsonb_extract_path_text(r.resource_json, 'id') AS \"id\",\n"
    + "  jsonb_extract_path_text(r.resource_json, 'birthDate') AS \"birthDate\"\n"
    + "FROM PatientTable AS r";

@test:Config {}
function testSimplePatientView() returns error? {
    postgresql:Client dbClient = check new (host, username, password, database, port);

    // Ensure the test table exists.
    _ = check dbClient->execute(`
        CREATE TABLE IF NOT EXISTS PatientTable (resource_json JSONB)
    `);

    // Clean slate.
    _ = check dbClient->execute(`DELETE FROM PatientTable`);

    // Insert a sample Patient resource.
    _ = check dbClient->execute(`
        INSERT INTO PatientTable (resource_json)
        VALUES ('{"resourceType":"Patient","id":"p1","birthDate":"1990-01-01"}')
    `);

    // Generate SQL from the ViewDefinition.
    json viewDef = {
        "resource": "Patient",
        "select": [{
            "column": [
                {"name": "id", "path": "id"},
                {"name": "birthDate", "path": "birthDate"}
            ]
        }]
    };
    TranspilerContext ctx = {
        resourceColumn: "resource_json",
        tableName: "PatientTable",
        filterByResourceType: false
    };
    string viewSql = check generateQuery(viewDef, ctx);

    // Assert the transpiler produces the exact expected SQL.
    // This ties the database test to the SQL generator — if the generated SQL
    // changes, this test fails, preventing silent divergence.
    test:assertEquals(viewSql, EXPECTED_PATIENT_VIEW_SQL, "Generated SQL must match expected");

    // Create the view using a compile-time template literal.
    // Ballerina's sql module requires ParameterizedQuery, which can only be
    // created from compile-time template literals — runtime string injection
    // is intentionally not supported.
    _ = check dbClient->execute(`
        CREATE OR REPLACE VIEW patient_test_view AS
        SELECT
          jsonb_extract_path_text(r.resource_json, 'id') AS "id",
          jsonb_extract_path_text(r.resource_json, 'birthDate') AS "birthDate"
        FROM PatientTable AS r
    `);

    // Query the view and assert results.
    stream<PatientRow, sql:Error?> resultStream = dbClient->query(
        `SELECT id, "birthDate" FROM patient_test_view`
    );
    PatientRow[] rows = check from PatientRow row in resultStream select row;

    test:assertEquals(rows.length(), 1, "Expected one row in the view");
    if rows.length() > 0 {
        test:assertEquals(rows[0].id, "p1", "Expected patient id 'p1'");
        test:assertEquals(rows[0].birthDate, "1990-01-01", "Expected birthDate '1990-01-01'");
    }

    // Cleanup.
    _ = check dbClient->execute(`DROP VIEW IF EXISTS patient_test_view`);
    check dbClient.close();
}
