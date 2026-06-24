trigger AccountRollupTrigger on Account (
    after insert, after update, after delete, after undelete
) {
    AccountRollupTriggerHandler.run();
}
