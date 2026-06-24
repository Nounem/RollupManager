public with sharing class RollupConfigProvider {

    public static List<RollupHelper.RollupConfig> getConfigs(String childObject) {
        List<RollupHelper.RollupConfig> configs = new List<RollupHelper.RollupConfig>();
        if (String.isBlank(childObject)) return configs;

        for (Rollup_Config__mdt row : [
            SELECT Active__c,
                   ChildObject__c,
                   RelationshipField__c,
                   FieldToAggregate__c,
                   AggregateFunction__c,
                   ParentObject__c,
                   TargetField__c,
                   FilterCriteria__c,
                   ParentFilter__c,
                   WatchedFields__c,
                   ExecutionOrder__c
            FROM Rollup_Config__mdt
            WHERE Active__c = true
            AND ChildObject__c = :childObject
            ORDER BY ExecutionOrder__c ASC NULLS LAST, DeveloperName ASC
        ]) {
            configs.add(fromMetadata(row));
        }

        return configs;
    }

    @TestVisible
    private static RollupHelper.RollupConfig fromMetadata(Rollup_Config__mdt row) {
        RollupHelper.RollupConfig config = new RollupHelper.RollupConfig();
        config.childObject = row.ChildObject__c;
        config.relationshipField = row.RelationshipField__c;
        config.fieldToAggregate = String.isBlank(row.FieldToAggregate__c)
            ? null
            : row.FieldToAggregate__c.trim();
        config.aggregateFunction = row.AggregateFunction__c;
        config.parentObject = row.ParentObject__c;
        config.targetField = row.TargetField__c;
        config.filterCriteria = String.isBlank(row.FilterCriteria__c)
            ? null
            : row.FilterCriteria__c.trim();
        config.parentFilter = String.isBlank(row.ParentFilter__c)
            ? null
            : row.ParentFilter__c.trim();
        config.alwaysRecalculate = false;
        config.watchedFields = parseWatchedFields(row.WatchedFields__c);
        return config;
    }

    @TestVisible
    private static Set<String> parseWatchedFields(String value) {
        Set<String> fields = new Set<String>();
        if (String.isBlank(value)) return fields;

        for (String rawField : value.split(',')) {
            String fieldName = rawField.trim();
            if (String.isNotBlank(fieldName)) {
                fields.add(fieldName);
            }
        }

        return fields;
    }
}
