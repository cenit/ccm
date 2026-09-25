function New-DynamoDbTaskPolicy {
    <#
    .SYNOPSIS
        Builds the scoped IAM policy JSON granting an ECS task role CRUD access to
        a set of DynamoDB tables and their indexes. Pure (no AWS calls); used by
        setup-aws-infrastructure.ps1 section 11b. Mirrors the EnableS3 policy shape.
    .OUTPUTS
        System.String — the policy document as JSON.
    #>
    param(
        [Parameter(Mandatory)][string]$AwsRegion,
        [Parameter(Mandatory)][string]$AwsAccountId,
        [Parameter(Mandatory)][string[]]$TableNames
    )
    $resources = foreach ($name in $TableNames) {
        "arn:aws:dynamodb:${AwsRegion}:${AwsAccountId}:table/$name"
        "arn:aws:dynamodb:${AwsRegion}:${AwsAccountId}:table/$name/index/*"
    }
    $policy = [ordered]@{
        Version   = "2012-10-17"
        Statement = @(
            [ordered]@{
                Effect   = "Allow"
                Action   = @(
                    "dynamodb:GetItem", "dynamodb:BatchGetItem", "dynamodb:Query", "dynamodb:Scan",
                    "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:BatchWriteItem"
                )
                Resource = @($resources)
            }
        )
    }
    return ($policy | ConvertTo-Json -Depth 6)
}
