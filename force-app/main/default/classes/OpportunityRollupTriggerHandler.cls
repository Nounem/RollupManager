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
        return RollupConfigProvider.getConfigs('Opportunity');
    }
}
