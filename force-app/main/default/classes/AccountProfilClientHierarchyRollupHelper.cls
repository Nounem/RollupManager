public without sharing class AccountProfilClientHierarchyRollupHelper {

    private static final String ACCOUNT_OBJECT = 'Account';
    private static final String PROFILE_OBJECT = 'Profil_client__c';
    private static final String PARENT_FIELD = 'ParentId';

    @TestVisible
    private static final List<String> LAST_ERRORS = new List<String>();

    public static void recalculate(
        List<Account> newList,
        List<Account> oldList,
        Boolean isInsert,
        Boolean isUpdate,
        Boolean isDelete,
        Boolean isUndelete
    ) {
        LAST_ERRORS.clear();

        List<HierarchyConfig> configs = loadConfigs();
        if (configs.isEmpty()) return;

        Impact impact = collectImpact(configs, newList, oldList, isInsert, isUpdate, isDelete, isUndelete);
        if (impact.accountIds.isEmpty() && impact.profileIdsToResetByKey.isEmpty()) return;

        Set<String> accountFields = accountFieldsFor(configs);
        Map<Id, SObject> rootsAndAncestors = collectAccountsAndAncestors(impact.accountIds, accountFields);
        Set<Id> rootIds = new Set<Id>(rootsAndAncestors.keySet());
        Map<Id, SObject> profilesToUpdate = new Map<Id, SObject>();

        for (HierarchyConfig config : configs) {
            try {
                Map<Id, Decimal> profileAmounts = calculateProfileAmounts(
                    config,
                    rootIds,
                    rootsAndAncestors,
                    accountFields
                );

                for (Id profileId : impact.profileIdsToResetByKey.get(config.key())) {
                    if (!profileAmounts.containsKey(profileId)) {
                        profileAmounts.put(profileId, 0);
                    }
                }

                addProfileUpdates(config, profileAmounts, profilesToUpdate);
            } catch (Exception e) {
                log('Config Account ignoree [' + config.summary() + '] : ' + e.getMessage());
            }
        }

        updateProfiles(profilesToUpdate);
    }

    private static List<HierarchyConfig> loadConfigs() {
        List<HierarchyConfig> configs = new List<HierarchyConfig>();

        for (RollupHelper.RollupConfig rollupConfig : RollupConfigProvider.getConfigs(ACCOUNT_OBJECT)) {
            try {
                HierarchyConfig config = new HierarchyConfig(rollupConfig);
                validateConfig(config);
                configs.add(config);
            } catch (Exception e) {
                log('Config Account ignoree : ' + e.getMessage());
            }
        }

        return configs;
    }

    private static void validateConfig(HierarchyConfig config) {
        if (config.rollup.childObject != ACCOUNT_OBJECT) {
            throw new AccountHierarchyRollupException('childObject doit etre Account');
        }
        if (config.rollup.parentObject != PROFILE_OBJECT) {
            throw new AccountHierarchyRollupException('parentObject doit etre Profil_client__c');
        }
        if (config.rollup.aggregateFunction != 'SUM') {
            throw new AccountHierarchyRollupException('seule la fonction SUM est supportee pour ce rollup hierarchique');
        }

        Map<String, Schema.SObjectField> accountFields =
            Account.SObjectType.getDescribe().fields.getMap();
        Map<String, Schema.SObjectField> profileFields =
            Profil_client__c.SObjectType.getDescribe().fields.getMap();

        assertField(accountFields, ACCOUNT_OBJECT, config.rollup.relationshipField);
        assertField(accountFields, ACCOUNT_OBJECT, config.rollup.fieldToAggregate);
        assertField(profileFields, PROFILE_OBJECT, config.rollup.targetField);

        if (!isNumeric(accountFields.get(config.rollup.fieldToAggregate).getDescribe())) {
            throw new AccountHierarchyRollupException(
                'fieldToAggregate doit etre numerique : Account.' + config.rollup.fieldToAggregate
            );
        }
        if (!isNumeric(profileFields.get(config.rollup.targetField).getDescribe())) {
            throw new AccountHierarchyRollupException(
                'targetField doit etre numerique : Profil_client__c.' + config.rollup.targetField
            );
        }
    }

    private static Impact collectImpact(
        List<HierarchyConfig> configs,
        List<Account> newList,
        List<Account> oldList,
        Boolean isInsert,
        Boolean isUpdate,
        Boolean isDelete,
        Boolean isUndelete
    ) {
        Impact impact = new Impact(configs);

        if (isInsert || isUndelete) {
            for (Account account : newList) {
                addAccountAndParent(impact.accountIds, account);
            }
            return impact;
        }

        if (isDelete) {
            for (Account oldAccount : oldList) {
                addAccountAndParent(impact.accountIds, oldAccount);
                addProfilesToReset(configs, impact, oldAccount);
            }
            return impact;
        }

        if (isUpdate) {
            for (Integer i = 0; i < newList.size(); i++) {
                Account newAccount = newList[i];
                Account oldAccount = oldList[i];
                if (!isRelevantChange(configs, newAccount, oldAccount)) continue;

                addAccountAndParent(impact.accountIds, newAccount);
                addAccountAndParent(impact.accountIds, oldAccount);
                addProfilesToResetForChangedRelationships(configs, impact, newAccount, oldAccount);
            }
        }

        return impact;
    }

    private static Boolean isRelevantChange(
        List<HierarchyConfig> configs,
        Account newAccount,
        Account oldAccount
    ) {
        if (newAccount.ParentId != oldAccount.ParentId) return true;

        for (HierarchyConfig config : configs) {
            for (String fieldName : config.watchedFields()) {
                if (fieldChanged(newAccount, oldAccount, fieldName)) return true;
            }
        }

        return false;
    }

    private static Set<String> accountFieldsFor(List<HierarchyConfig> configs) {
        Set<String> fields = new Set<String>{ 'Id', PARENT_FIELD };
        for (HierarchyConfig config : configs) {
            fields.add(config.rollup.relationshipField);
            fields.add(config.rollup.fieldToAggregate);
        }
        return fields;
    }

    private static void addAccountAndParent(Set<Id> accountIds, Account account) {
        if (account == null) return;
        if (account.Id != null) accountIds.add(account.Id);
        if (account.ParentId != null) accountIds.add(account.ParentId);
    }

    private static void addProfilesToReset(
        List<HierarchyConfig> configs,
        Impact impact,
        Account account
    ) {
        for (HierarchyConfig config : configs) {
            Id profileId = getId(account, config.rollup.relationshipField);
            if (profileId != null) {
                impact.profileIdsToResetByKey.get(config.key()).add(profileId);
            }
        }
    }

    private static void addProfilesToResetForChangedRelationships(
        List<HierarchyConfig> configs,
        Impact impact,
        Account newAccount,
        Account oldAccount
    ) {
        for (HierarchyConfig config : configs) {
            Id oldProfileId = getId(oldAccount, config.rollup.relationshipField);
            Id newProfileId = getId(newAccount, config.rollup.relationshipField);
            if (oldProfileId != null && oldProfileId != newProfileId) {
                impact.profileIdsToResetByKey.get(config.key()).add(oldProfileId);
            }
        }
    }

    private static Map<Id, SObject> collectAccountsAndAncestors(
        Set<Id> startingAccountIds,
        Set<String> fields
    ) {
        Map<Id, SObject> accountsById = new Map<Id, SObject>();
        Set<Id> frontier = new Set<Id>(startingAccountIds);

        while (!frontier.isEmpty()) {
            Set<Id> idsToQuery = new Set<Id>(frontier);
            frontier.clear();

            for (SObject account : queryAccountsByIds(idsToQuery, fields)) {
                if (accountsById.containsKey(account.Id)) continue;

                accountsById.put(account.Id, account);
                Id parentId = getId(account, PARENT_FIELD);
                if (parentId != null && !accountsById.containsKey(parentId)) {
                    frontier.add(parentId);
                }
            }
        }

        return accountsById;
    }

    private static Map<Id, Decimal> calculateProfileAmounts(
        HierarchyConfig config,
        Set<Id> rootIds,
        Map<Id, SObject> knownAccounts,
        Set<String> fields
    ) {
        Map<Id, SObject> subtreeAccounts = collectSubtreeAccounts(rootIds, knownAccounts, fields);
        Map<Id, List<Id>> childrenByParent = buildChildrenByParent(subtreeAccounts);
        Map<Id, Decimal> profileAmounts = new Map<Id, Decimal>();

        for (Id rootId : rootIds) {
            SObject root = subtreeAccounts.get(rootId);
            if (root == null) continue;

            Id profileId = getId(root, config.rollup.relationshipField);
            if (profileId == null) continue;

            profileAmounts.put(
                profileId,
                calculateSubtreeAmount(config, rootId, subtreeAccounts, childrenByParent)
            );
        }

        return profileAmounts;
    }

    private static Map<Id, SObject> collectSubtreeAccounts(
        Set<Id> rootIds,
        Map<Id, SObject> knownAccounts,
        Set<String> fields
    ) {
        Map<Id, SObject> accountsById = new Map<Id, SObject>();
        for (Id rootId : rootIds) {
            if (knownAccounts.containsKey(rootId)) {
                accountsById.put(rootId, knownAccounts.get(rootId));
            }
        }

        Set<Id> frontier = new Set<Id>(rootIds);
        while (!frontier.isEmpty()) {
            Set<Id> parentIds = new Set<Id>(frontier);
            frontier.clear();

            for (SObject child : queryAccountsByParentIds(parentIds, fields)) {
                if (accountsById.containsKey(child.Id)) continue;

                accountsById.put(child.Id, child);
                frontier.add(child.Id);
            }
        }

        return accountsById;
    }

    private static List<SObject> queryAccountsByIds(Set<Id> idsToQuery, Set<String> fields) {
        String soql = 'SELECT ' + String.join(new List<String>(fields), ', ')
            + ' FROM Account WHERE Id IN :idsToQuery';
        return Database.query(soql);
    }

    private static List<SObject> queryAccountsByParentIds(Set<Id> parentIds, Set<String> fields) {
        String soql = 'SELECT ' + String.join(new List<String>(fields), ', ')
            + ' FROM Account WHERE ParentId IN :parentIds';
        return Database.query(soql);
    }

    private static Map<Id, List<Id>> buildChildrenByParent(Map<Id, SObject> accountsById) {
        Map<Id, List<Id>> childrenByParent = new Map<Id, List<Id>>();

        for (SObject account : accountsById.values()) {
            Id parentId = getId(account, PARENT_FIELD);
            if (parentId == null || !accountsById.containsKey(parentId)) continue;

            if (!childrenByParent.containsKey(parentId)) {
                childrenByParent.put(parentId, new List<Id>());
            }
            childrenByParent.get(parentId).add(account.Id);
        }

        return childrenByParent;
    }

    private static Decimal calculateSubtreeAmount(
        HierarchyConfig config,
        Id rootId,
        Map<Id, SObject> accountsById,
        Map<Id, List<Id>> childrenByParent
    ) {
        Decimal total = 0;
        List<Id> stack = new List<Id>{ rootId };

        while (!stack.isEmpty()) {
            Id accountId = stack.remove(stack.size() - 1);
            SObject account = accountsById.get(accountId);
            if (account == null) continue;

            total += decimalValue(account.get(config.rollup.fieldToAggregate));

            if (childrenByParent.containsKey(accountId)) {
                stack.addAll(childrenByParent.get(accountId));
            }
        }

        return total;
    }

    private static void addProfileUpdates(
        HierarchyConfig config,
        Map<Id, Decimal> profileAmounts,
        Map<Id, SObject> profilesToUpdate
    ) {
        if (profileAmounts.isEmpty()) return;

        Schema.DescribeFieldResult targetFieldDescribe =
            Profil_client__c.SObjectType.getDescribe().fields.getMap().get(config.rollup.targetField).getDescribe();
        if (!targetFieldDescribe.isUpdateable()) {
            log('Profil_client__c.' + config.rollup.targetField
                + ' est non modifiable. Convertir le champ en Currency avant execution reelle.');
            return;
        }

        for (Id profileId : profileAmounts.keySet()) {
            if (!profilesToUpdate.containsKey(profileId)) {
                profilesToUpdate.put(profileId, Profil_client__c.SObjectType.newSObject(profileId));
            }
            profilesToUpdate.get(profileId).put(config.rollup.targetField, profileAmounts.get(profileId));
        }
    }

    private static void updateProfiles(Map<Id, SObject> profilesToUpdate) {
        if (profilesToUpdate.isEmpty()) return;

        List<Database.SaveResult> results = Database.update(profilesToUpdate.values(), false);
        List<SObject> profiles = profilesToUpdate.values();
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                log('Echec mise a jour Profil_client__c '
                    + profiles[i].Id + ' : ' + results[i].getErrors()[0].getMessage());
            }
        }
    }

    private static void assertField(
        Map<String, Schema.SObjectField> fields,
        String objectName,
        String fieldName
    ) {
        if (String.isBlank(fieldName) || !fields.containsKey(fieldName)) {
            throw new AccountHierarchyRollupException('champ introuvable : ' + objectName + '.' + fieldName);
        }
    }

    private static Boolean isNumeric(Schema.DescribeFieldResult fieldDescribe) {
        Schema.DisplayType type = fieldDescribe.getType();
        return type == Schema.DisplayType.Currency
            || type == Schema.DisplayType.Double
            || type == Schema.DisplayType.Integer
            || type == Schema.DisplayType.Long
            || type == Schema.DisplayType.Percent;
    }

    private static Boolean fieldChanged(SObject newRec, SObject oldRec, String fieldName) {
        try {
            return newRec.get(fieldName) != oldRec.get(fieldName);
        } catch (Exception e) {
            return true;
        }
    }

    private static Id getId(SObject record, String fieldName) {
        if (record == null || String.isBlank(fieldName)) return null;
        Object value = record.get(fieldName);
        return value == null ? null : (Id) value;
    }

    private static Decimal decimalValue(Object value) {
        return value == null ? 0 : (Decimal) value;
    }

    private static void log(String message) {
        LAST_ERRORS.add(message);
        System.debug(LoggingLevel.ERROR, message);
    }

    private class HierarchyConfig {
        private RollupHelper.RollupConfig rollup;

        private HierarchyConfig(RollupHelper.RollupConfig rollup) {
            this.rollup = rollup;
        }

        private String key() {
            return rollup.relationshipField + ':' + rollup.fieldToAggregate + ':' + rollup.targetField;
        }

        private String summary() {
            return rollup.childObject + '.' + rollup.fieldToAggregate
                + ' -> ' + rollup.parentObject + '.' + rollup.targetField;
        }

        private Set<String> watchedFields() {
            Set<String> fields = new Set<String>{ PARENT_FIELD, rollup.relationshipField, rollup.fieldToAggregate };
            if (rollup.watchedFields != null) {
                fields.addAll(rollup.watchedFields);
            }
            return fields;
        }
    }

    private class Impact {
        private Set<Id> accountIds = new Set<Id>();
        private Map<String, Set<Id>> profileIdsToResetByKey = new Map<String, Set<Id>>();

        private Impact(List<HierarchyConfig> configs) {
            for (HierarchyConfig config : configs) {
                profileIdsToResetByKey.put(config.key(), new Set<Id>());
            }
        }
    }

    private class AccountHierarchyRollupException extends Exception {}
}
