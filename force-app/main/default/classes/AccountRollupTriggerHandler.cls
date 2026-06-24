public class AccountRollupTriggerHandler {

    public static void run() {
        if (RollupTriggerControl.disabled) return;

        AccountProfilClientHierarchyRollupHelper.recalculate(
            Trigger.new,
            Trigger.old,
            Trigger.isInsert,
            Trigger.isUpdate,
            Trigger.isDelete,
            Trigger.isUndelete
        );
    }
}
