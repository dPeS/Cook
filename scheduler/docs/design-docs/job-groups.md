# Job groups design doc
 

## Problem

 

Many jobs submitted to cook are actually part of a logical group, for example, a spark driver submits 10 spark executors. 

The driver is aware that the 10 executors are a group and manages them as so, but cook has no idea. 

Cook is unable to offer the executors options about how they are placed on hosts because it doesn't know they are related.

 

In another scenario, a single batch of map reduce jobs must be managed by a separate process if it wants to monitor the batch

for stragglers or fail the batch if one task fails. 

Additionally, the process must keep track of the whole batch and keep the data historically for reporting and debugging.

 

## High level idea

 

Add a new field on jobs to define a uuid for a group the job belongs to. 

The client can then set additional metadata on the group to inform cook on options for the group.

 

For example, job groups could allow for group:

 

1. Querying

2. Reporting

3. Failure semantics (if one fails, all fail)

4. Host placement (all on same host, unique hosts, balanced across hosts)

5. Straggler detection and response

 

## Changes to the api

 

Add a new endpoint to create a group and manage group prefences such has host placement preferences, failure semantics and straggler detection.

 

Add another field on job's for a group uuid, generated by the client. 

Any jobs that share the group uuid will be treated as in the same group (as long as they are owned by the same user, otherwise, an error should be thrown).

 

Add a new endpoint to query for the jobs in a group.

 

###Open question: Should jobs be able to set a group id without explicitly creating it?

####Choice: Yes

This makes it easier for clients to group jobs when they don't intend to set any preferences about the group. 

It also makes the failure cases (create a group, then client fails) a little more managable. 

However, this means we either need to allow group preferences to be mutable since a client could first submit jobs then change preferences

or assert that the only way to have a group with non-default preferences is to create it first.

####Choice: No

This makes the protocol a bit simplier to understand (if you want to use groups, explicitly create them first) but adds a step to the submission process

and is more heavy weight for clients that just want to use the defaults and use groups for querying.

 

###Open question: Should groups be part of a single batch submission (to /rawscheduler)?

####Choice: Yes

This reduces the number of requests a client needs to make (and reduces the failure surface) and allows for a simplier submission protocol in the case that a group of jobs spans only one submission

####Choice: No

The explicit handshake of creating a group first makes the multiple submission batches case simplier.

 

## Changes to the database

### Open question: Have a `group` entity which has a list of `job` entities or have the `job` entity have a ref to a group

#### Choice: `group` entity with list of `job`s 

This allows for a job to be a member of multiple groups (a hierachy of jobs) as multiple groups can contain the same job.

This complicates some of the other preference logic.

#### Choice: `job` entity has `group` ref

This is more intuitive and makes handling of preference logic simplier. Adding multiple groups will likely require more code changes.
Could make the group ref a multi (a job references multiple groups)

## Host placement semantics

We want to allow users to specify how jobs in a group should be placed. 

Some choices a user could specify are:

1. Unique hosts 
2. Balanced across hosts
3. All on one host
4. All hosts must have the same attribute value (as in, once you schedule the first job, all other jobs must be put on hosts with the same attribute/value pair)
5. No preference (this is the default)

In all cases a user accepts that putting a restriction on where the group should be scheduled can negatively impact scheduling latency. 

In the case of (3), it is *not* guarenteed that the full group will run on the host concurrently.

Here are some use cases for the following semantics:

1. I have a job that measures something about the host. Having multiple jobs on the same host is fine, but wasteful and makes it harder to decide how many jobs to schedule
2. I have a group of jobs that are network bound. Putting many jobs on the same host will negatively impact the performance of all of them.
3. My jobs have a lot of cross communication, having them connect on the loopback device is good for peformance
4. I'm running on Amazon and I get charged for cross AZ communication. Having all the jobs run in the same AZ (I don't care which) is important to reduce unnecessary costs
5. My jobs are completely independent, they can run anywhere

An important note is that all of these choices create a quasi-heterogenuous cluster in that once one job is placed, the remaining jobs must only consider a subset of the hosts. However, unlike in a fully heterogenuous cluster, Cook has some freedom in deciding where to place the job which can help mitigate some of the fairness concerns with a heterogenuous cluster. Therefore, there is no change needed to ranking for this, but we should change the rebalancer to avoid preempting jobs on a host when the job that we are making room for won't run on the host.

### Changes to db

Add attribute on groups entity, `group/host-placement` which will be a ref to an entity with two fields:

1. `host-placement/type` will be of type datomic enum
2. `host-placement/parameters` will be a ref

The type will be take one of the following values:

* `host-placement.type/unique`
* `host-placement.type/balanced`
* `host-placement.type/one`
* `host-placement.type/attribute-equals`
* `host-placement.type/all`

And parameters will point to either nil in the case of all the type except `host-placement.type/attribute-equals` which will point to a entity with a single attribute `host-placement.attribute-equals/attribute` which will be a string.

### Changes to the api

The group entity will have a field "host_placement" which will be a map with a field "type" and a field "parameters". "type" will take a value in the set {"unique", "balanced", "one", "attribute-equals" and "all"}. "parameters" will be a map and the keys in the map will be dependent on the "type". At the moment, the only valid key will be "attribute" and applies to "attribute-equals". If "attribute" is not defined when using "attribute-equals", we should throw an exception.

If "host-placement" is not defined, it defaults to {"type": "all"}.