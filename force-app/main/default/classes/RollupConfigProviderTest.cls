@IsTest
private class RollupConfigProviderTest {

    @IsTest
    static void getConfigsReadsActiveMetadataTest() {
        List<RollupHelper.RollupConfig> configs = RollupConfigProvider.getConfigs('Opportunity');

        System.assert(!configs.isEmpty(), 'Le provider doit lire le record metadata exemple Opportunity');
        RollupHelper.RollupConfig config = configs[0];
        System.assertEquals('Opportunity', config.childObject);
        System.assertEquals('AccountId', config.relationshipField);
        System.assertEquals('Amount', config.fieldToAggregate);
        System.assertEquals('SUM', config.aggregateFunction);
        System.assertEquals('Account', config.parentObject);
        System.assertEquals('Total_CA__c', config.targetField);
        System.assertEquals(new Set<String>{ 'Amount' }, config.watchedFields);
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
