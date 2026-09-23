BeforeAll {
    $script:Schema = Join-Path $PSScriptRoot ".." "ecs-config.schema.json"
}

Describe "ecs-config.schema.json DynamoDB" {
    It "accepts a valid DynamoDb config" {
        $json = @'
{ "ProjectName": "demo", "EnableDynamoDb": true,
  "DynamoDbTables": [
    { "Name": "demo-scopes", "PartitionKey": { "Name": "scopeId", "Type": "S" } },
    { "Name": "demo-assign", "PartitionKey": { "Name": "userKey" }, "SortKey": { "Name": "sk" } } ] }
'@
        Test-Json -Json $json -SchemaFile $script:Schema | Should -BeTrue
    }

    It "rejects a table missing PartitionKey" {
        $json = '{ "ProjectName": "demo", "DynamoDbTables": [ { "Name": "x" } ] }'
        Test-Json -Json $json -SchemaFile $script:Schema -ErrorAction SilentlyContinue | Should -BeFalse
    }

    It "rejects a bad key Type" {
        $json = '{ "ProjectName": "demo", "DynamoDbTables": [ { "Name": "x", "PartitionKey": { "Name": "k", "Type": "Z" } } ] }'
        Test-Json -Json $json -SchemaFile $script:Schema -ErrorAction SilentlyContinue | Should -BeFalse
    }

    It "still accepts a config with no DynamoDb keys" {
        Test-Json -Json '{ "ProjectName": "demo" }' -SchemaFile $script:Schema | Should -BeTrue
    }
}

Describe "New-DynamoDbTaskPolicy" {
    # Import via the manifest (not a direct dot-source) so this suite also fails
    # if the function ever drops out of FunctionsToExport again.
    BeforeAll { Import-Module (Join-Path $PSScriptRoot ".." "CCM.psd1") -Force }

    It "scopes actions to the given tables and their indexes" {
        $doc = New-DynamoDbTaskPolicy -AwsRegion "eu-central-1" -AwsAccountId "123456789012" `
            -TableNames @("demo-scopes", "demo-assign") | ConvertFrom-Json
        $resources = $doc.Statement[0].Resource
        $resources | Should -Contain "arn:aws:dynamodb:eu-central-1:123456789012:table/demo-scopes"
        $resources | Should -Contain "arn:aws:dynamodb:eu-central-1:123456789012:table/demo-scopes/index/*"
        $resources | Should -Contain "arn:aws:dynamodb:eu-central-1:123456789012:table/demo-assign"
        $doc.Statement[0].Action | Should -Contain "dynamodb:Query"
        $doc.Statement[0].Action | Should -Contain "dynamodb:UpdateItem"
        $doc.Statement[0].Action | Should -Not -Contain "dynamodb:DeleteTable"
    }
}
