// ═══════════════════════════════════════════════════════════════════════════
// MODÈLE GÉNÉRIQUE — copier pour chaque nouvel objet enfant
// Renommer    : <ObjetEnfant>RollupTrigger.trigger
// Modifier    : la ligne "trigger ... on <ObjetEnfant>" + la section CONFIG
// Ne pas toucher au reste
// ═══════════════════════════════════════════════════════════════════════════
trigger OpportunityRollupTrigger on Opportunity (
    after insert, after update, after delete, after undelete
) {
    // ─── CONFIG ───────────────────────────────────────────────────────────────
    List<RollupHelper.RollupConfig> configs = new List<RollupHelper.RollupConfig>();

    // ── Rollup 1 : SUM Amount → Account (tous les comptes) ───────────────────
    RollupHelper.RollupConfig config1 = new RollupHelper.RollupConfig();
    config1.childObject        = 'Opportunity';
    config1.relationshipField  = 'AccountId';
    config1.fieldToAggregate   = 'Amount';
    config1.aggregateFunction  = 'SUM';           // SUM | COUNT | MIN | MAX | AVG
    config1.parentObject       = 'Account';
    config1.targetField        = 'Total_CA__c';
    config1.filterCriteria     = null;            // null = tous les enfants
    config1.parentFilter       = null;            // null = tous les parents
    config1.alwaysRecalculate  = false;
    configs.add(config1);

    // ── Rollup 2 : SUM Amount → Account de type Client uniquement ────────────
    // parentFilter restreint les parents éligibles à ceux dont le RecordType = Client.
    // Les Accounts d'un autre type ne reçoivent pas la mise à jour, même s'ils ont des Opps.
    /*
    RollupHelper.RollupConfig config2 = new RollupHelper.RollupConfig();
    config2.childObject        = 'Opportunity';
    config2.relationshipField  = 'AccountId';
    config2.fieldToAggregate   = 'Amount';
    config2.aggregateFunction  = 'SUM';
    config2.parentObject       = 'Account';
    config2.targetField        = 'Total_CA_Client__c';
    config2.filterCriteria     = 'StageName = \'Closed Won\'';
    config2.parentFilter       = 'RecordType.DeveloperName = \'Client\'';
    config2.alwaysRecalculate  = true;            // StageName n'est pas fieldToAggregate
    configs.add(config2);
    */

    // ── Rollup 3 : COUNT Opportunités ouvertes → Account ─────────────────────
    /*
    RollupHelper.RollupConfig config3 = new RollupHelper.RollupConfig();
    config3.childObject        = 'Opportunity';
    config3.relationshipField  = 'AccountId';
    config3.fieldToAggregate   = null;
    config3.aggregateFunction  = 'COUNT';
    config3.parentObject       = 'Account';
    config3.targetField        = 'Nb_Opportunites__c';
    config3.filterCriteria     = 'IsClosed = false';
    config3.parentFilter       = null;
    config3.alwaysRecalculate  = true;            // IsClosed n'est pas fieldToAggregate
    configs.add(config3);
    */
    // ─────────────────────────────────────────────────────────────────────────

    RollupHelper.calculateAll(
        configs,
        Trigger.new,
        Trigger.old,
        Trigger.isInsert,
        Trigger.isUpdate,
        Trigger.isDelete,
        Trigger.isUndelete
    );
}
