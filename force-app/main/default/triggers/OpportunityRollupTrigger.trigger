trigger OpportunityRollupTrigger on Opportunity (
    after insert, after update, after delete, after undelete
) {
    OpportunityRollupTriggerHandler.run();
}
