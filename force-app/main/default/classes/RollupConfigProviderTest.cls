@IsTest
private class RollupConfigProviderTest {

    @IsTest
    static void fromMetadataMapsFieldsTest() {
        Rollup_Config__mdt row = new Rollup_Config__mdt();
        row.ChildObject__c = 'Case';
        row.RelationshipField__c = 'AccountId';
        row.FieldToAggregate__c = null;
        row.AggregateFunction__c = 'COUNT';
        row.ParentObject__c = 'Account';
        row.TargetField__c = 'Nb_Cases__c';
        row.FilterCriteria__c = 'Status != \'Closed\'';
        row.ParentFilter__c = null;
        row.WatchedFields__c = 'Status, AccountId';

        RollupHelper.RollupConfig config = RollupConfigProvider.fromMetadata(row);

        System.assertEquals('Case', config.childObject);
        System.assertEquals('AccountId', config.relationshipField);
        System.assertEquals(null, config.fieldToAggregate);
        System.assertEquals('COUNT', config.aggregateFunction);
        System.assertEquals('Account', config.parentObject);
        System.assertEquals('Nb_Cases__c', config.targetField);
        System.assertEquals('Status != \'Closed\'', config.filterCriteria);
        System.assertEquals(new Set<String>{ 'Status', 'AccountId' }, config.watchedFields);
    }

    @IsTest
    static void parseWatchedFieldsTrimsAndSkipsBlankValuesTest() {
        Set<String> fields = RollupConfigProvider.parseWatchedFields(' Amount, StageName, , IsClosed ');

        System.assertEquals(new Set<String>{ 'Amount', 'StageName', 'IsClosed' }, fields);
    }

    @IsTest
    static void getConfigsReturnsEmptyListForUnknownChildObjectTest() {
        System.assertEquals(0, RollupConfigProvider.getConfigs('Objet_Inexistant__c').size());
    }
}
