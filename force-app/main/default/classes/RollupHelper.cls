/**
 * Moteur générique de calcul rollup entre deux objets Salesforce.
 *
 * without sharing : le calcul agrège TOUS les enregistrements enfants indépendamment
 * des droits du contexte d'exécution, identique au comportement natif des RUSF.
 * Si la restriction par profil est voulue, passer à "with sharing".
 */
public without sharing class RollupHelper {

    // Évite d'appeler getGlobalDescribe() plusieurs fois dans la même transaction
    private static final Map<String, Schema.SObjectType> SOBJECT_CACHE =
        new Map<String, Schema.SObjectType>();

    // Clé : 'ChildObject:TargetField'
    // Permet à plusieurs rollups sur le même objet de coexister sans bloquer mutuellement
    @TestVisible
    private static final Set<String> RUNNING = new Set<String>();

    @TestVisible
    private static final List<String> LAST_ERRORS = new List<String>();

    // ─── Modèle de configuration ──────────────────────────────────────────────

    public class RollupConfig {
        public String  childObject;         // API name objet enfant     ex : 'Opportunity'
        public String  relationshipField;   // Champ relation sur enfant  ex : 'AccountId'
        public String  fieldToAggregate;    // Champ à agréger            ex : 'Amount' (null si COUNT)
        public String  aggregateFunction;   // SUM | COUNT | MIN | MAX | AVG
        public String  parentObject;        // API name objet parent      ex : 'Account'
        public String  targetField;         // Champ cible sur parent     ex : 'Total_CA__c'
        public String  filterCriteria;      // Clause WHERE sur les enfants — null = aucun filtre
        public String  parentFilter;        // Clause WHERE sur les parents — null = tous les parents
                                            // ex : 'RecordType.DeveloperName = \'Client\''
                                            // Seuls les parents qui matchent reçoivent la mise à jour
        // Mettre true si filterCriteria porte sur un champ autre que fieldToAggregate
        // (ex : filtre sur StageName mais on agrège Amount).
        // Par défaut false : recalcul uniquement si fieldToAggregate ou relationshipField change.
        public Boolean alwaysRecalculate = false;
        public Set<String> watchedFields;
        public Boolean throwOnError = false;
    }

    public class RollupException extends Exception {}

    // ─── Point d'entrée : un seul rollup ─────────────────────────────────────

    public static void calculate(
        RollupConfig  config,
        List<SObject> newList,
        List<SObject> oldList,
        Boolean       isInsert,
        Boolean       isUpdate,
        Boolean       isDelete,
        Boolean       isUndelete
    ) {
        normalizeConfig(config);
        assertConfig(config);

        String key = config.childObject + ':' + config.targetField;
        if (RUNNING.contains(key)) return;

        Set<Id> parentIds = collectParentIds(
            config, newList, oldList, isInsert, isUpdate, isDelete, isUndelete
        );
        if (parentIds.isEmpty()) return;

        // Filtre sur le parent : exclure les parents qui ne matchent pas parentFilter
        if (String.isNotBlank(config.parentFilter)) {
            parentIds = filterParentIds(config, parentIds);
            if (parentIds.isEmpty()) return;
        }

        RUNNING.add(key);
        try {
            persist(config, parentIds, aggregate(config, parentIds));
        } finally {
            RUNNING.remove(key);
        }
    }

    // ─── Point d'entrée : plusieurs rollups sur le même objet enfant ──────────

    public static void calculateAll(
        List<RollupConfig> configs,
        List<SObject>      newList,
        List<SObject>      oldList,
        Boolean            isInsert,
        Boolean            isUpdate,
        Boolean            isDelete,
        Boolean            isUndelete
    ) {
        LAST_ERRORS.clear();
        if (configs == null || configs.isEmpty()) return;

        for (RollupConfig config : configs) {
            try {
                calculate(config, newList, oldList, isInsert, isUpdate, isDelete, isUndelete);
            } catch (Exception e) {
                String message = 'Rollup config ignoree [' + configSummary(config) + '] : ' + e.getMessage();
                LAST_ERRORS.add(message);
                System.debug(LoggingLevel.ERROR, message);
            }
        }
    }

    // ─── Étape 1 : identifier les IDs parent impactés ─────────────────────────

    private static Set<Id> collectParentIds(
        RollupConfig  config,
        List<SObject> newList,
        List<SObject> oldList,
        Boolean       isInsert,
        Boolean       isUpdate,
        Boolean       isDelete,
        Boolean       isUndelete
    ) {
        Set<Id> ids = new Set<Id>();

        if (isDelete) {
            for (SObject rec : oldList) {
                Id pid = (Id) rec.get(config.relationshipField);
                if (pid != null) ids.add(pid);
            }

        } else if (isInsert || isUndelete) {
            for (SObject rec : newList) {
                Id pid = (Id) rec.get(config.relationshipField);
                if (pid != null) ids.add(pid);
            }

        } else if (isUpdate) {
            for (Integer i = 0; i < newList.size(); i++) {
                Id newPid = (Id) newList[i].get(config.relationshipField);
                Id oldPid = (Id) oldList[i].get(config.relationshipField);

                Boolean relationChanged = newPid != oldPid;

                // COUNT ne dépend d'aucun champ agrégé : seule la relation compte
                Boolean valueChanged = hasWatchedFieldChanged(config, newList[i], oldList[i]);

                // alwaysRecalculate : recalcul systématique si le filterCriteria
                // porte sur un champ autre que fieldToAggregate
                Boolean forceRecalc = config.alwaysRecalculate == true && (newPid != null || oldPid != null);

                if (forceRecalc || relationChanged || valueChanged) {
                    if (newPid != null) ids.add(newPid);
                    if (oldPid != null) ids.add(oldPid); // reparentage : les deux parents sont recalculés
                }
            }
        }

        return ids;
    }

    // ─── Étape 2 : requête d'agrégation SOQL dynamique ───────────────────────

    private static Map<Id, Decimal> aggregate(RollupConfig config, Set<Id> parentIds) {
        Map<Id, Decimal> valueMap = new Map<Id, Decimal>();
        Decimal defaultValue = defaultValueFor(config);
        for (Id pid : parentIds) valueMap.put(pid, defaultValue);

        String aggExpr = config.aggregateFunction == 'COUNT'
            ? 'COUNT(Id)'
            : config.aggregateFunction + '(' + config.fieldToAggregate + ')';

        String soql = 'SELECT '  + config.relationshipField + ' parentId, '
                    +              aggExpr                   + ' rollupValue '
                    + 'FROM '    + config.childObject
                    + ' WHERE '  + config.relationshipField  + ' IN :parentIds';

        if (String.isNotBlank(config.filterCriteria)) {
            soql += ' AND (' + config.filterCriteria + ')';
        }

        soql += ' GROUP BY ' + config.relationshipField;

        for (AggregateResult ar : Database.query(soql)) {
            Id     pid    = (Id) ar.get('parentId');
            Object rawVal = ar.get('rollupValue');

            if (pid == null || rawVal == null) continue;

            // COUNT retourne Integer, SUM / MIN / MAX / AVG retournent Decimal
            valueMap.put(pid, rawVal instanceof Integer
                ? Decimal.valueOf((Integer) rawVal)
                : (Decimal) rawVal);
        }

        return valueMap;
    }

    // ─── Étape 3 : écriture sur les parents ───────────────────────────────────

    private static void persist(
        RollupConfig     config,
        Set<Id>          parentIds,
        Map<Id, Decimal> valueMap
    ) {
        Schema.SObjectType parentType = getSObjectType(config.parentObject);
        List<SObject> toUpdate = new List<SObject>();

        for (Id pid : parentIds) {
            SObject parent = parentType.newSObject(pid);
            parent.put(config.targetField, valueMap.containsKey(pid) ? valueMap.get(pid) : defaultValueFor(config));
            toUpdate.add(parent);
        }

        if (toUpdate.isEmpty()) return;

        // allOrNone = false : un parent en erreur ne bloque pas les autres
        List<Database.SaveResult> results = Database.update(toUpdate, false);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                System.debug(
                    LoggingLevel.ERROR,
                    'RollupHelper — échec parent ' + toUpdate[i].Id
                    + ' [' + config.parentObject + '.' + config.targetField + '] : '
                    + results[i].getErrors()[0].getMessage()
                );
                if (config.throwOnError == true) {
                    throw new RollupException(
                        'Echec parent ' + toUpdate[i].Id + ' [' + config.parentObject + '.'
                        + config.targetField + '] : ' + results[i].getErrors()[0].getMessage()
                    );
                }
            }
        }
    }

    // ─── Filtre sur le parent ─────────────────────────────────────────────────
    // Retourne uniquement les IDs dont le parent vérifie parentFilter.
    // Les parents exclus ne reçoivent ni mise à jour ni remise à zéro.

    private static Set<Id> filterParentIds(RollupConfig config, Set<Id> parentIds) {
        String soql = 'SELECT Id FROM ' + config.parentObject
                    + ' WHERE Id IN :parentIds AND (' + config.parentFilter + ')';
        Set<Id> allowed = new Set<Id>();
        for (SObject rec : Database.query(soql)) {
            allowed.add(rec.Id);
        }
        return allowed;
    }

    // ─── Utilitaires ──────────────────────────────────────────────────────────

    private static Schema.SObjectType getSObjectType(String objectName) {
        if (!SOBJECT_CACHE.containsKey(objectName)) {
            SOBJECT_CACHE.put(objectName, Schema.getGlobalDescribe().get(objectName));
        }
        return SOBJECT_CACHE.get(objectName);
    }

    private static void normalizeConfig(RollupConfig c) {
        if (c != null && String.isNotBlank(c.aggregateFunction)) {
            c.aggregateFunction = c.aggregateFunction.toUpperCase();
        }
    }

    private static void assertConfig(RollupConfig c) {
        if (c == null)                           throw new RollupException('config est null');
        if (String.isBlank(c.childObject))       throw new RollupException('childObject est obligatoire');
        if (String.isBlank(c.relationshipField)) throw new RollupException('relationshipField est obligatoire');
        if (String.isBlank(c.aggregateFunction)) throw new RollupException('aggregateFunction est obligatoire');
        if (String.isBlank(c.parentObject))      throw new RollupException('parentObject est obligatoire');
        if (String.isBlank(c.targetField))       throw new RollupException('targetField est obligatoire');
        if (c.aggregateFunction != 'COUNT' && String.isBlank(c.fieldToAggregate)) {
            throw new RollupException('fieldToAggregate est obligatoire pour ' + c.aggregateFunction);
        }
        Set<String> valid = new Set<String>{ 'SUM', 'COUNT', 'MIN', 'MAX', 'AVG' };
        if (!valid.contains(c.aggregateFunction.toUpperCase())) {
            throw new RollupException('aggregateFunction invalide : ' + c.aggregateFunction);
        }
        assertSchema(c);
    }

    private static void assertSchema(RollupConfig c) {
        Schema.SObjectType childType = getSObjectType(c.childObject);
        if (childType == null) {
            throw new RollupException('childObject introuvable : ' + c.childObject);
        }

        Schema.SObjectType parentType = getSObjectType(c.parentObject);
        if (parentType == null) {
            throw new RollupException('parentObject introuvable : ' + c.parentObject);
        }

        Map<String, Schema.SObjectField> childFields = childType.getDescribe().fields.getMap();
        Map<String, Schema.SObjectField> parentFields = parentType.getDescribe().fields.getMap();

        assertFieldExists(childFields, c.childObject, c.relationshipField);
        assertFieldExists(parentFields, c.parentObject, c.targetField);

        Schema.DescribeFieldResult targetDescribe = parentFields.get(c.targetField).getDescribe();
        if (!isNumeric(targetDescribe)) {
            throw new RollupException('targetField doit etre numerique : ' + c.parentObject + '.' + c.targetField);
        }

        if (c.aggregateFunction != 'COUNT') {
            assertFieldExists(childFields, c.childObject, c.fieldToAggregate);
            Schema.DescribeFieldResult aggregateDescribe = childFields.get(c.fieldToAggregate).getDescribe();
            if (!isNumeric(aggregateDescribe)) {
                throw new RollupException(
                    'fieldToAggregate doit etre numerique pour ' + c.aggregateFunction
                    + ' : ' + c.childObject + '.' + c.fieldToAggregate
                );
            }
        }

        if (c.watchedFields != null) {
            for (String fieldName : c.watchedFields) {
                assertFieldExists(childFields, c.childObject, fieldName);
            }
        }
    }

    private static void assertFieldExists(
        Map<String, Schema.SObjectField> fields,
        String objectName,
        String fieldName
    ) {
        if (String.isBlank(fieldName) || !fields.containsKey(fieldName)) {
            throw new RollupException('champ introuvable : ' + objectName + '.' + fieldName);
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

    private static Boolean hasWatchedFieldChanged(
        RollupConfig config,
        SObject newRec,
        SObject oldRec
    ) {
        if (config.watchedFields != null && !config.watchedFields.isEmpty()) {
            for (String fieldName : config.watchedFields) {
                if (fieldChanged(newRec, oldRec, fieldName)) return true;
            }
            return false;
        }

        if (config.aggregateFunction == 'COUNT') return false;
        return fieldChanged(newRec, oldRec, config.fieldToAggregate);
    }

    private static Boolean fieldChanged(SObject newRec, SObject oldRec, String fieldName) {
        try {
            return newRec.get(fieldName) != oldRec.get(fieldName);
        } catch (Exception e) {
            return true;
        }
    }

    private static Decimal defaultValueFor(RollupConfig config) {
        return config.aggregateFunction == 'SUM' || config.aggregateFunction == 'COUNT'
            ? 0
            : null;
    }

    private static String configSummary(RollupConfig config) {
        if (config == null) return 'config null';
        return String.valueOf(config.childObject) + ' -> '
            + String.valueOf(config.parentObject) + '.'
            + String.valueOf(config.targetField);
    }
}
