# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A SQL-on-FHIR v2 implementation in Ballerina targeting PostgreSQL. It processes FHIR [ViewDefinitions](https://build.fhir.org/ig/FHIR/sql-on-fhir-v2/) to generate PostgreSQL JSONB queries, built on top of a FHIRPath-to-PostgreSQL transpiler. The `typescript-mssql-src/` directory contains the reference TypeScript implementation targeting T-SQL/MS SQL Server that is being incrementally ported to Ballerina.

## Build & Run Commands

- **Build:** `bal build`
- **Run:** `bal run`
- **Test all:** `bal test`
- **Run single test:** `bal test --tests <testFunctionName>`

Requires Ballerina distribution `2201.12.10`.

## Architecture

The Ballerina transpiler is a three-stage pipeline:

1. **Scanner** (`scanner.bal`) - Lexical analysis: FHIRPath string -> token stream. Hand-written scanner (not generated).
2. **Parser** (`parser.bal`) - Recursive descent parser: token stream -> AST. Follows the grammar defined in `grammar.g4`.
3. **Transpiler** (`transpiler.bal`) - AST walker: walks the expression tree and emits PostgreSQL JSONB SQL (using `->`, `->>`, `jsonb_array_elements`, etc.).

Supporting files:
- `token_type.bal` - `TokenType` enum (all token kinds)
- `token.bal` - `FhirPathToken` record and constructors
- `expr.bal` - AST node types (`Expr` union: `BinaryExpr`, `LiteralExpr`, `IdentifierExpr`, `FunctionExpr`, `MemberAccessExpr`, `IndexerExpr`) and constructors

Entry point: `transpile(expression, context)` in `transpiler.bal` orchestrates scan -> parse -> walk.

### ViewDefinition layer

SQL-on-FHIR ViewDefinition processing sits above the FHIRPath transpiler:

- `view_definition.bal` - Core types: `ViewDefinition`, `ViewDefinitionSelect`, `ViewDefinitionColumn`, `ViewDefinitionWhere`, `ViewDefinitionColumnTag`, `SelectCombination`
- `select_combination_expander.bal` - `expandCombinations()`: expands all possible `unionAll` branch combinations from a ViewDefinition's `select` array into a flat list of `SelectCombination` records (Cartesian product of union choices)
- `query_generator.bal` - Query generation layer: `generateQuery()` / `generateAllSelectStatements()` / `generateStatementForCombination()` / `generateSimpleStatement()`. Simple (no forEach, no repeat) path is implemented; forEach and repeat return a not-yet-implemented error.

### TranspilerContext

The `TranspilerContext` record controls SQL generation:
- `resourceAlias` - SQL table alias (e.g., `"r"`)
- `resourceColumn` - JSONB column name (default `"resource"`)
- `constants` - External `%name` variable references
- `iterationContext`, `currentForEachAlias`, `forEachSource`, `forEachPathSegments` - forEach/where iteration state

### FHIR-specific behavior

- `KNOWN_ARRAY_FIELDS` / `ALWAYS_ARRAY_FIELDS` - Fields that require `jsonb_array_elements` unwinding
- `POLYMORPHIC_FIELDS` - FHIR choice types (e.g., `value[x]`) with `TYPE_SUFFIX_MAP` for suffix resolution
- `FHIR_TO_PG_TYPE_MAP` - Maps FHIR primitive types to PostgreSQL types
- `inferSqlType()` supports tag-based type overrides (`pg/type`, `ansi/type`)

### TypeScript reference (`typescript-mssql-src/`)

Full SQL-on-FHIR v2 implementation targeting T-SQL/MS SQL Server. Key components being ported:
- `queryGenerator/SelectCombinationExpander.ts` → `select_combination_expander.bal` ✓
- `queryGenerator.ts` (`generateSimpleStatement`) → `query_generator.bal` (simple path) ✓
- `queryGenerator/ForEachProcessor.ts`, `RepeatProcessor.ts`, `SelectClauseBuilder.ts`, etc. — pending
- `fhirpath/transpiler.ts` — ANTLR4-based FHIRPath-to-T-SQL transpiler (Ballerina has its own hand-rolled equivalent)

Features are ported incrementally. All Ballerina code uses functional paradigm (isolated functions, immutable-style record passing).

## Key Conventions

- All scanner/parser/transpiler functions are `isolated` (Ballerina's concurrency safety).
- State is threaded through functions via immutable-style record passing (e.g., `ScannerState`, `ParserState`) rather than mutation.
- AST nodes use a `kind` discriminator field for type narrowing (e.g., `"Binary"`, `"Literal"`).
- Licensed under Apache 2.0 (WSO2 LLC).
