public class OpportunityRollupTriggerHandler {

    public static void run() {
        if (RollupTriggerControl.disabled) return;

        RollupHelper.calculateAll(
            buildConfigs(),
            Trigger.new,
            Trigger.old,
            Trigger.isInsert,
            Trigger.isUpdate,
            Trigger.isDelete,
            Trigger.isUndelete
        );
    }

    @TestVisible
    private static List<RollupHelper.RollupConfig> buildConfigs() {
        List<RollupHelper.RollupConfig> configs = new List<RollupHelper.RollupConfig>();

        RollupHelper.RollupConfig totalAmount = new RollupHelper.RollupConfig();
        totalAmount.childObject = 'Opportunity';
        totalAmount.relationshipField = 'AccountId';
        totalAmount.fieldToAggregate = 'Amount';
        totalAmount.aggregateFunction = 'SUM';
        totalAmount.parentObject = 'Account';
        totalAmount.targetField = 'Total_CA__c';
        totalAmount.filterCriteria = null;
        totalAmount.parentFilter = null;
        totalAmount.alwaysRecalculate = false;
        totalAmount.watchedFields = new Set<String>{ 'Amount' };
        configs.add(totalAmount);

        return configs;
    }
}
