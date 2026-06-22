# RollupHelper — Documentation technique

---

## Vue d'ensemble

`RollupHelper` est un moteur de calcul rollup générique en Apex.
Il remplace les Roll-Up Summary Fields (RUSF) natifs de Salesforce en les étendant
aux relations **Lookup** (pas seulement Master-Detail) et à toute combinaison d'objets.

**Principe** : un trigger `after insert/update/delete/undelete` collecte les IDs parent
impactés, exécute une requête SOQL d'agrégation dynamique, et met à jour le champ
cible en un seul DML.

```
Objet enfant (trigger)
    └── RollupHelper.calculateAll()
            ├── collectParentIds()   → identifie les parents impactés
            ├── aggregate()          → SOQL dynamique GROUP BY
            └── persist()            → Database.update(allOrNone: false)
                    └── Objet parent (champ cible mis à jour)
```

---

## Fichiers du projet

| Fichier | Rôle | Modifier ? |
|---|---|---|
| `classes/RollupHelper.cls` | Moteur générique | **Jamais** |
| `triggers/OpportunityRollupTrigger.trigger` | Template de trigger | **Section CONFIG uniquement** |
| `classes/RollupHelperTest.cls` | 13 tests unitaires | Adapter les valeurs si besoin |
| `objects/Account/fields/Total_CA__c.field-meta.xml` | Exemple de champ cible | Dupliquer par nouveau champ |

---

## Les 8 paramètres de configuration

```apex
RollupHelper.RollupConfig config = new RollupHelper.RollupConfig();
config.childObject        = 'Opportunity';           // 1 — API name objet enfant
config.relationshipField  = 'AccountId';             // 2 — champ de relation sur l'enfant
config.fieldToAggregate   = 'Amount';                // 3 — champ à agréger (null si COUNT)
config.aggregateFunction  = 'SUM';                   // 4 — SUM | COUNT | MIN | MAX | AVG
config.parentObject       = 'Account';               // 5 — API name objet parent
config.targetField        = 'Total_CA__c';           // 6 — champ cible sur le parent
config.filterCriteria     = null;                    // 7 — clause WHERE SOQL (null = aucun filtre)
config.alwaysRecalculate  = false;                   // 8 — voir section dédiée ci-dessous
```

---

## filterCriteria — syntaxe complète

Le filtre est une chaîne SOQL injectée directement dans la clause `WHERE`.
Les parenthèses sont ajoutées automatiquement autour du filtre pour isoler
les conditions `OR` du reste de la requête.

> **Sécurité** : `filterCriteria` est défini dans le code Apex par le développeur,
> pas depuis une saisie utilisateur. Il n'y a pas de risque d'injection SOQL.
> Si cette valeur venait un jour d'une source externe, valider avant d'injecter.

### Aucun filtre

```apex
config.filterCriteria = null; // tous les enfants sont agrégés
```

### Une condition

```apex
config.filterCriteria = 'StageName = \'Closed Won\'';
config.filterCriteria = 'Amount > 0';
config.filterCriteria = 'IsWon = true';
config.filterCriteria = 'RecordType.DeveloperName = \'Standard\'';
```

### Plusieurs conditions — AND

```apex
config.filterCriteria = 'StageName = \'Closed Won\' AND Amount > 1000';
config.filterCriteria = 'IsClosed = true AND Amount > 0 AND Type != null';
```

### Plusieurs conditions — OR

```apex
config.filterCriteria = 'StageName = \'Closed Won\' OR StageName = \'Verbal Agreement\'';
```

### Combinaison AND + OR avec parenthèses

```apex
config.filterCriteria = '(StageName = \'Closed Won\' OR StageName = \'Closed Lost\') AND Amount > 500';
config.filterCriteria = 'Amount > 0 AND (Type = \'New Business\' OR Type = \'Renewal\')';
```

### Opérateur IN

```apex
config.filterCriteria = 'StageName IN (\'Closed Won\', \'Closed Lost\', \'Verbal Agreement\')';
config.filterCriteria = 'Type IN (\'New Business\', \'Renewal\', \'Add-On\')';
```

### Opérateurs de comparaison

```apex
config.filterCriteria = 'Amount >= 1000';            // supérieur ou égal
config.filterCriteria = 'Amount != 0';               // différent de zéro
config.filterCriteria = 'Name LIKE \'%Client%\'';    // contient
config.filterCriteria = 'Name LIKE \'A%\'';          // commence par
```

### Dates dynamiques SOQL

```apex
config.filterCriteria = 'CloseDate = THIS_YEAR';
config.filterCriteria = 'CloseDate = THIS_QUARTER';
config.filterCriteria = 'CloseDate = LAST_N_DAYS:30';
config.filterCriteria = 'CreatedDate >= LAST_YEAR AND CloseDate <= THIS_YEAR';
```

### Champs null

```apex
config.filterCriteria = 'AccountId != null';               // exclure les orphelins
config.filterCriteria = 'Montant_HT__c != null AND Montant_HT__c > 0';
```

---

## parentFilter — filtrer les parents éligibles

`parentFilter` est une clause WHERE SOQL appliquée sur l'objet **parent**.
Seuls les parents qui satisfont cette condition reçoivent la mise à jour.
Les parents exclus ne sont **ni mis à jour ni remis à zéro** — ils sont simplement ignorés.

### Exemples

```apex
// Uniquement les Accounts de type Client (RecordType)
config.parentFilter = 'RecordType.DeveloperName = \'Client\'';

// Uniquement les Accounts actifs
config.parentFilter = 'Active__c = true';

// Uniquement les Accounts dont le propriétaire est dans une région
config.parentFilter = 'Owner.Region__c = \'France\'';

// Aucun filtre parent (défaut) — tous les parents reçoivent la mise à jour
config.parentFilter = null;
```

### Différence avec filterCriteria

| | filterCriteria | parentFilter |
|---|---|---|
| Appliqué sur | L'objet **enfant** | L'objet **parent** |
| Effet | Exclut certains enfants du calcul | Exclut certains parents du résultat |
| Exemple | Ne compter que les Opps `Closed Won` | Ne mettre à jour que les Accounts `Client` |

Les deux peuvent être combinés :

```apex
config.filterCriteria = 'StageName = \'Closed Won\'';          // enfants filtrés
config.parentFilter   = 'RecordType.DeveloperName = \'Client\''; // parents filtrés
// → SUM des Opps Closed Won, uniquement pour les Accounts de type Client
```

---

## alwaysRecalculate — quand l'utiliser

**Problème** : le moteur est optimisé pour ne recalculer que si `fieldToAggregate`
ou `relationshipField` a changé. Si le filtre porte sur un **autre champ**
(ex : `StageName = 'Closed Won'` alors que `fieldToAggregate = 'Amount'`),
le moteur ne recalcule pas quand `StageName` change, même si le résultat change.

**Solution** : passer `alwaysRecalculate = true` pour forcer le recalcul à chaque UPDATE.

```apex
// SANS alwaysRecalculate : StageName passe de Prospecting à Closed Won
// → Amount n'a pas changé → pas de recalcul → Total_CA__c est faux ❌
config.filterCriteria    = 'StageName = \'Closed Won\'';
config.alwaysRecalculate = false; // MAUVAIS dans ce cas

// AVEC alwaysRecalculate : recalcul à chaque UPDATE, même si Amount n'a pas changé
config.filterCriteria    = 'StageName = \'Closed Won\'';
config.alwaysRecalculate = true;  // CORRECT ✓
```

**Règle pratique** :

| filterCriteria porte sur... | alwaysRecalculate |
|---|---|
| Aucun filtre | `false` |
| `fieldToAggregate` uniquement | `false` |
| Un autre champ (StageName, Type, IsWon...) | `true` |
| Dates dynamiques (`THIS_YEAR`, etc.) | `true` |

---

## Fonctions d'agrégation

| Fonction | Description | Type champ à agréger | Type champ cible |
|---|---|---|---|
| `SUM` | Somme | Number / Currency | Number / Currency |
| `COUNT` | Nombre d'enregistrements | Ignoré (mettre `null`) | Number |
| `MIN` | Valeur minimale | Number / Currency / Date | Même type |
| `MAX` | Valeur maximale | Number / Currency / Date | Même type |
| `AVG` | Moyenne | Number / Currency | Number / Currency |

---

## Plusieurs champs à calculer — les 3 scénarios

### Scénario 1 — Mêmes enfants, même parent, plusieurs champs

Un seul trigger, plusieurs configs dans `calculateAll()`.
Chaque config cible un champ différent sur le même parent.

```
Opportunity (un seul trigger)
    ├── config1 : SUM(Amount)  → Account.Total_CA__c
    └── config2 : COUNT(Id)    → Account.Nb_Opportunites__c
```

```apex
trigger OpportunityRollupTrigger on Opportunity ( ... ) {
    List<RollupHelper.RollupConfig> configs = new List<RollupHelper.RollupConfig>();

    RollupHelper.RollupConfig c1 = new RollupHelper.RollupConfig();
    c1.childObject = 'Opportunity'; c1.relationshipField = 'AccountId';
    c1.fieldToAggregate = 'Amount'; c1.aggregateFunction = 'SUM';
    c1.parentObject = 'Account'; c1.targetField = 'Total_CA__c';
    c1.filterCriteria = null; c1.parentFilter = null;
    configs.add(c1);

    RollupHelper.RollupConfig c2 = new RollupHelper.RollupConfig();
    c2.childObject = 'Opportunity'; c2.relationshipField = 'AccountId';
    c2.fieldToAggregate = null; c2.aggregateFunction = 'COUNT';
    c2.parentObject = 'Account'; c2.targetField = 'Nb_Opportunites__c';
    c2.filterCriteria = null; c2.parentFilter = null;
    configs.add(c2);

    RollupHelper.calculateAll(configs, Trigger.new, Trigger.old,
        Trigger.isInsert, Trigger.isUpdate, Trigger.isDelete, Trigger.isUndelete);
}
```

### Scénario 2 — Enfants différents, même parent, champs différents

Un trigger par objet enfant. Chaque trigger met à jour un champ différent sur le même parent.
Pas de conflit : les clés de récursion sont différentes (`Opportunity:Total_CA__c` vs `Case:Nb_Cases__c`).

```
Opportunity (trigger 1)  →  Account.Total_CA__c
Case        (trigger 2)  →  Account.Nb_Cases__c
```

```apex
// OpportunityRollupTrigger.trigger
config.childObject = 'Opportunity'; config.targetField = 'Total_CA__c';

// CaseRollupTrigger.trigger
config.childObject = 'Case'; config.targetField = 'Nb_Cases__c';
```

### Scénario 3 — Même parent, filtre différent par segment

Deux configs sur les mêmes enfants mais avec des filtres différents,
pour des champs cibles différents.

```
Opportunity (un seul trigger)
    ├── config1 : SUM(Amount) filtre Closed Won       → Account.Total_CA_Gagne__c
    └── config2 : SUM(Amount) filtre toutes les Opps  → Account.Total_CA_Pipeline__c
```

```apex
RollupHelper.RollupConfig c1 = new RollupHelper.RollupConfig();
c1.fieldToAggregate = 'Amount'; c1.aggregateFunction = 'SUM';
c1.targetField = 'Total_CA_Gagne__c';
c1.filterCriteria = 'StageName = \'Closed Won\'';
c1.alwaysRecalculate = true;
configs.add(c1);

RollupHelper.RollupConfig c2 = new RollupHelper.RollupConfig();
c2.fieldToAggregate = 'Amount'; c2.aggregateFunction = 'SUM';
c2.targetField = 'Total_CA_Pipeline__c';
c2.filterCriteria = null;
configs.add(c2);
```

---

## Plusieurs rollups sur le même objet enfant

Un seul trigger par objet. Pour plusieurs rollups, utiliser `calculateAll()` :

```apex
trigger OpportunityRollupTrigger on Opportunity (
    after insert, after update, after delete, after undelete
) {
    List<RollupHelper.RollupConfig> configs = new List<RollupHelper.RollupConfig>();

    // Rollup 1 : SUM Amount → Account
    RollupHelper.RollupConfig c1 = new RollupHelper.RollupConfig();
    c1.childObject = 'Opportunity'; c1.relationshipField = 'AccountId';
    c1.fieldToAggregate = 'Amount'; c1.aggregateFunction = 'SUM';
    c1.parentObject = 'Account'; c1.targetField = 'Total_CA__c';
    c1.filterCriteria = null; c1.alwaysRecalculate = false;
    configs.add(c1);

    // Rollup 2 : COUNT → Account
    RollupHelper.RollupConfig c2 = new RollupHelper.RollupConfig();
    c2.childObject = 'Opportunity'; c2.relationshipField = 'AccountId';
    c2.fieldToAggregate = null; c2.aggregateFunction = 'COUNT';
    c2.parentObject = 'Account'; c2.targetField = 'Nb_Opportunites__c';
    c2.filterCriteria = null; c2.alwaysRecalculate = false;
    configs.add(c2);

    RollupHelper.calculateAll(
        configs, Trigger.new, Trigger.old,
        Trigger.isInsert, Trigger.isUpdate, Trigger.isDelete, Trigger.isUndelete
    );
}
```

---

## Décisions de conception

### without sharing

`RollupHelper` est déclaré `without sharing`. Cela signifie que le calcul
agrège **tous** les enregistrements enfants, indépendamment du profil ou
des règles de partage de l'utilisateur qui a déclenché l'action.

C'est le comportement voulu pour un rollup : le champ cible sur le parent
doit refléter la réalité complète des données, pas une vue filtrée.

Si la restriction par profil est intentionnelle (ex : un commercial ne doit
voir que son propre total), remplacer par `with sharing` dans `RollupHelper.cls`.

### Database.update(allOrNone: false)

Les parents sont mis à jour avec `allOrNone = false`. Un parent qui échoue
(champ verrouillé, validation rule) n'empêche pas la mise à jour des autres.
Les erreurs sont loguées en `System.debug(LoggingLevel.ERROR, ...)`.

Pour remonter les erreurs plus visiblement, remplacer le `System.debug`
par un enregistrement dans un objet de log dédié.

### Garde anti-récursion

La clé de récursion est `childObject:targetField`.
Deux configs différentes sur le même objet enfant (ex : `Opportunity:Total_CA__c`
et `Opportunity:Nb_Opportunites__c`) ont des clés différentes et ne se bloquent pas.

Si le DML dans `persist()` déclenche un trigger qui revient sur le même objet enfant
avec la même config, le second appel retourne immédiatement sans rien faire.

---

## Créer un nouveau rollup — 6 étapes

### 1 — Créer le champ cible sur l'objet parent

```xml
<!-- objects/MonObjet__c/fields/MonChampRollup__c.field-meta.xml -->
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>MonChampRollup__c</fullName>
    <label>Mon Champ Rollup</label>
    <type>Currency</type>
    <precision>18</precision>
    <scale>2</scale>
</CustomField>
```

Ou le créer dans Setup → Object Manager → [objet parent] → Fields → New.

### 2 — Copier et renommer le trigger template

```bash
cp force-app/main/default/triggers/OpportunityRollupTrigger.trigger \
   force-app/main/default/triggers/MonEnfantRollupTrigger.trigger

cp force-app/main/default/triggers/OpportunityRollupTrigger.trigger-meta.xml \
   force-app/main/default/triggers/MonEnfantRollupTrigger.trigger-meta.xml
```

### 3 — Modifier la ligne trigger et la section CONFIG

Changer `trigger OpportunityRollupTrigger on Opportunity` par l'objet cible,
puis remplir les 8 paramètres.

### 4 — Déployer

```bash
sf project deploy start --source-dir force-app
```

### 5 — Recalcul initial des données existantes

Les nouvelles modifications déclenchent le trigger automatiquement.
Les données existantes nécessitent un appel Apex anonyme ou un batch dédié.

### 6 — Vérifier les tests

```bash
sf apex run test --class-names RollupHelperTest --result-format human
```

Couverture cible : > 85 %.

---

## Exemples de configuration complets

### SUM des Opportunités gagnées → Account

```apex
config.childObject       = 'Opportunity';
config.relationshipField = 'AccountId';
config.fieldToAggregate  = 'Amount';
config.aggregateFunction = 'SUM';
config.parentObject      = 'Account';
config.targetField       = 'Total_CA_Gagne__c';
config.filterCriteria    = 'StageName = \'Closed Won\'';
config.alwaysRecalculate = true; // StageName n'est pas fieldToAggregate
```

### COUNT des Cases ouverts → Account

```apex
config.childObject       = 'Case';
config.relationshipField = 'AccountId';
config.fieldToAggregate  = null;
config.aggregateFunction = 'COUNT';
config.parentObject      = 'Account';
config.targetField       = 'Nb_Cases_Ouverts__c';
config.filterCriteria    = 'Status != \'Closed\'';
config.alwaysRecalculate = true; // Status n'est pas le champ agrégé
```

### MAX de la date de clôture → Account

```apex
config.childObject       = 'Opportunity';
config.relationshipField = 'AccountId';
config.fieldToAggregate  = 'CloseDate';
config.aggregateFunction = 'MAX';
config.parentObject      = 'Account';
config.targetField       = 'Derniere_Cloture__c';
config.filterCriteria    = 'IsWon = true';
config.alwaysRecalculate = true;
```

### SUM sur objets custom

```apex
config.childObject       = 'Ligne_Commande__c';
config.relationshipField = 'Commande__c';
config.fieldToAggregate  = 'Montant_HT__c';
config.aggregateFunction = 'SUM';
config.parentObject      = 'Commande__c';
config.targetField       = 'Total_HT__c';
config.filterCriteria    = 'Annule__c = false AND Montant_HT__c > 0';
config.alwaysRecalculate = false; // filtre porte uniquement sur champs non modifiables
```

---

## Règles importantes

**Un seul trigger par objet enfant.**
Si un trigger existe déjà, ajouter l'appel à `RollupHelper.calculateAll()` à l'intérieur.
Ne jamais créer deux triggers sur le même objet.

**Le champ cible doit être éditable.**
Les Formula Fields (champs calculés natifs) ne peuvent pas être mis à jour par du code.
Utiliser uniquement des champs Number, Currency, ou Date.

**Guillemets simples dans filterCriteria.**
En Apex, un String utilise des guillemets simples. Pour les inclure dans le filtre,
les échapper avec un backslash : `'StageName = \'Closed Won\''`.

**COUNT ne nécessite pas de fieldToAggregate.**
Passer `config.fieldToAggregate = null` pour COUNT. Toute autre valeur est ignorée.

---

## Cas gérés automatiquement

| Événement | Comportement |
|---|---|
| INSERT enfant | Recalcule le(s) parent(s) lié(s) |
| UPDATE `fieldToAggregate` | Recalcule si la valeur a changé |
| UPDATE `relationshipField` (reparentage) | Recalcule l'ancien parent ET le nouveau parent |
| UPDATE sans changement pertinent | Retour immédiat, aucun SOQL ni DML |
| UPDATE avec `alwaysRecalculate = true` | Recalcule à chaque UPDATE |
| DELETE enfant | Recalcule le parent qui perd l'enregistrement |
| UNDELETE enfant | Recalcule le parent qui récupère l'enregistrement |
| BULK (200 enregistrements) | Regroupe tous les parents uniques, 1 seul DML |
| Relation nulle (`AccountId` vide) | Ignoré silencieusement |
| Appel récursif (même clé) | Retour immédiat, récursion bloquée |
