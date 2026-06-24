@IsTest
private class OpportunityRollupTriggerHandlerTest {

    @TestSetup
    static void setup() {
        insert new Account(Name = 'Handler Account');
    }

    private static Account getAccount() {
        return [
            SELECT Id, Total_CA__c
            FROM Account
            WHERE Name = 'Handler Account'
            LIMIT 1
        ];
    }

    private static Opportunity buildOpp(Id accountId, Decimal amount) {
        return new Opportunity(
            AccountId = accountId,
            Name = 'Handler Opp ' + amount,
            Amount = amount,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
    }

    @IsTest
    static void buildConfigsTest() {
        List<RollupHelper.RollupConfig> configs = OpportunityRollupTriggerHandler.buildConfigs();

        System.assertEquals(1, configs.size(), 'Le handler doit exposer une config active');
        System.assertEquals('Opportunity', configs[0].childObject);
        System.assertEquals('AccountId', configs[0].relationshipField);
        System.assertEquals('Amount', configs[0].fieldToAggregate);
        System.assertEquals('SUM', configs[0].aggregateFunction);
        System.assertEquals('Account', configs[0].parentObject);
        System.assertEquals('Total_CA__c', configs[0].targetField);
        System.assertEquals(new Set<String>{ 'Amount' }, configs[0].watchedFields);
    }

    @IsTest
    static void triggerDelegatesToHandlerTest() {
        RollupTriggerControl.disabled = false;
        Account acc = getAccount();

        Test.startTest();
        insert new List<Opportunity>{
            buildOpp(acc.Id, 100),
            buildOpp(acc.Id, 200)
        };
        Test.stopTest();

        System.assertEquals(300, getAccount().Total_CA__c,
            'Le trigger doit deleguer au handler et recalculer le total');
    }

    @IsTest
    static void triggerBypassTest() {
        RollupTriggerControl.disabled = true;
        Account acc = getAccount();

        Test.startTest();
        insert buildOpp(acc.Id, 100);
        Test.stopTest();

        System.assertEquals(null, getAccount().Total_CA__c,
            'Le bypass doit empecher le handler de lancer le rollup');
        RollupTriggerControl.disabled = false;
    }
}
