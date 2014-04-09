//
//  QliqDBService.m
//  qliq
//
//  Created by Aleksey Garbarev on 12/3/12.
//
//

#import "DBCodingService.h"
#import "DBCoder_DBService.h"
#import "NSInvocation_Class.h"

#import "FMDatabase.h"
#import "FMDatabaseQueue.h"

@interface NSError(NSError_Shortcuts)

+ (NSError *) errorWithCode:(NSInteger) code description:(NSString *) description;

@end

@implementation NSError (NSError_Shortcuts)

+ (NSError *) errorWithCode:(NSInteger) code description:(NSString *) description{
    return [NSError errorWithDomain:@"com.dbcodingservice" code:code userInfo: @{ NSLocalizedDescriptionKey : description} ];
}

@end

@interface DBCodingService()


@end

@implementation DBCodingService {
    FMDatabase *database;
    FMDatabaseQueue *queue;
}

- (id) initWithDatabase:(FMDatabase *) _database
{
    self = [super init];
    if (self) {
        database = _database;
    }
    return self;
}

- (id)initWithDatabaseQueue:(FMDatabaseQueue *)_queue
{
    self = [super init];
    if (self) {
        queue = _queue;
    }
    return self;
}

#pragma mark - Working with FMDB

- (void)performBlock:(void(^)(FMDatabase *db))block
{
    if (queue) {
        [queue inDatabase:block];
    } else if (database) {
        block(database);
    } else {
        NSLog(@"Database is not set. Init with 'initWithQueue' or 'initWithDatabase'.");
    }
}

- (BOOL)executeUpdate:(NSString *)query withArgumentsInArray:(NSArray *)args
{
    __block BOOL success;
    [self performBlock:^(FMDatabase *db) {
        success = [db executeUpdate:query withArgumentsInArray:args];
    }];
    return success;
}

- (FMResultSet *)executeQuery:(NSString *)query withArgumentsInArray:(NSArray *)args
{
    __block FMResultSet *result;
    [self performBlock:^(FMDatabase *db) {
        result = [db executeQuery:query withArgumentsInArray:args];
    }];
    return result;
}

- (NSError *)lastError
{
    __block NSError *error;
    [self performBlock:^(FMDatabase *db) {
        error = [db lastError];
    }];
    return error;
}

- (sqlite_int64)lastInsertRowId
{
    __block sqlite_int64 lastRowId;
    [self performBlock:^(FMDatabase *db) {
        lastRowId = [db lastInsertRowId];
    }];
    return lastRowId;
}

#pragma mark - Changing DB

- (void) removeObjectsInCoder:(DBCoder *) coder{
    [coder enumerateToOneRelatedObjects:^id(id<DBCoding> object, Class objectClass) {
        return nil;
    }];
}

//To handle to-one relations
- (void) replaceObjectsInCoder:(DBCoder *) coder{
    //replace all db object with it's ids
    [coder enumerateToOneRelatedObjects:^id(id<DBCoding> object, Class objectClass) {
        __block id insertedId = nil;
        
        [self save:object withSchemeClass:objectClass completion:^(BOOL wasInserted, id objectId, NSError *error) {
            insertedId = objectId;
            if (error){
                NSLog(@"%@",[error localizedDescription]);
            }
        }];
        
        return insertedId;
    }];
}

//to handle to-many relations
- (void) saveRelationsWithId:(id)objectId inCoder:(DBCoder *)coder{
    
    [coder enumerateToManyRelationCoders:^(DBCoder *connection_coder) {
        /* Replace objects with their ID's */
        [self replaceObjectsInCoder:connection_coder];
        
        [connection_coder setPrimaryKey:objectId];
        
        /* Insert Or Update table*/
        [self insert:connection_coder update:YES error:nil];
    }];
    
}

- (void) save:(id<DBCoding>) object withSchemeClass:(Class)objectClass mode:(DBMode) mode completion:(DBSaveCompletion)completion{
    
    if (!object){
        NSError * error = [NSError errorWithCode:DBErrorCodeObjectIsNil description:@"Object to save can't be nil"];
        if (completion) completion(0, dbPrimaryKeyUndefined, error);
        return;
    }
    
    DBCoder * coder = [[DBCoder alloc] initWithDBObject:object as:objectClass];
    
    BOOL wasInserted = NO;
    id objectId = nil;
    NSError * error = nil;
    
    if (mode & DBModeToOne){
        [self replaceObjectsInCoder:coder];
    }else{
        [self removeObjectsInCoder:coder];
    }
    
    if (![self isExistCoder:coder]){
        wasInserted = YES;
        
        NSNumber * insertedId = [self insert:coder update:NO error:&error];
        
        objectId = [coder havePrimaryKey] ? [coder primaryKey] : insertedId;

        /* Set Primary Key */
        [self setPrimaryKey:objectId forObject:object asClass:objectClass];
        
    }else{
        [self update:coder error:&error];
        
        objectId = [coder primaryKey];
    }
    
    if (mode & DBModeToMany){
        [self saveRelationsWithId:objectId inCoder:coder];
    }
    
    if (completion) completion(wasInserted, objectId, error);
    
}

- (void) save:(id<DBCoding>) object withSchemeClass:(Class)objectClass completion:(DBSaveCompletion)completion{
    [self save:object withSchemeClass:objectClass mode:(DBModeToMany | DBModeToOne) completion:completion];
}

- (void) save:(id<DBCoding>) object completion:(DBSaveCompletion)completion{
    [self save:object withSchemeClass:[object class] mode:(DBModeToMany | DBModeToOne) completion:completion];
}

- (NSNumber *) insert:(DBCoder *) coder update:(BOOL) shouldUpdate error:(NSError **) error{
    
    __block NSNumber * insertedId = nil;
    
    [coder insertStatement:^(NSString *query, NSArray *args) {
        
        BOOL success = NO;
        
        if (query && args){
            
            success = [self executeUpdate:query withArgumentsInArray:args];
            insertedId = [NSNumber numberWithLongLong:[self lastInsertRowId]];

        }
        
        if (error && !success){
            [self setupDBError:error action:@"inserting to db" query:query args:args];
        }
        

        
    } replace:shouldUpdate];
        
    return insertedId;
}

- (void) update:(DBCoder *) coder error:(NSError **) error{
    
    [coder updateStatement:^(NSString *query, NSArray *args) {
        BOOL success = NO;
        
        if (query && args){
            success = [self executeUpdate:query withArgumentsInArray:args];
        }
        
        if (error && !success){
            [self setupDBError:error action:@"updating db"];
        }
    }];
 
}

- (void) setupDBError:(NSError **) error action:(NSString *) action{
    NSError * dbError = [self lastError];
    if (dbError){
        * error = dbError;
    }else{
        * error = [NSError errorWithCode:DBErrorCodeUnknown description:[NSString stringWithFormat:@"Something gone wrong while %@",action]];
    }
}

- (void) setupDBError:(NSError **) error action:(NSString *) action query:(NSString *) query args:(NSArray *) args{
    NSError * dbError = [self lastError];
    if (dbError){
        * error = dbError;
    }else{
        * error = [NSError errorWithCode:DBErrorCodeUnknown description:[NSString stringWithFormat:@"Something gone wrong while %@.\nQuery: %@\nArgs: %@",action,query,args]];
    }
}


#pragma mark - Access to DB

- (BOOL) isExistCoder:(DBCoder *) coder{
    
    BOOL isExist = NO;
    
    if ([coder havePrimaryKey]){
        id existingObject = [self objectWithId:[coder primaryKey] andClass:[coder rootObjectClass]];
        isExist =  (existingObject != nil);
    }
    return isExist;
}

- (BOOL) isExist:(id<DBCoding>) object{
    
    BOOL isExist = NO;
    
    id pkValue = [(NSObject *)object valueForKey:[object dbPKProperty]];
    BOOL isCorrect = [DBCoder isCorrectPrimaryKey:pkValue];
    
    if (isCorrect){
        id existObject = [self objectWithId:[(NSObject *)object valueForKey:[object dbPKProperty]] andClass:[object class]];
        isExist =  (existObject != nil);
    }
    
    return isExist;
}

- (void) setPrimaryKey:(id) key forObject:(id) object asClass:(Class) asClass{
    NSString * pkProperty = [NSInvocation resultOfInvokingTarget:object withSelector:@selector(dbPKProperty) ofClass:asClass];
    [(NSObject *)object setValue:key forKey:pkProperty];
}

- (id) objectOfClass:(Class) objectClass withSchemeClass:(Class) asClass fromDecoder:(DBCoder *) decoder{
  
    id<DBCoding> object = nil;
    if (objectClass && decoder){
        
        /* Init with decoder */
        object = [NSInvocation resultOfInvokingTarget:[objectClass alloc] withSelector:@selector(initWithDBCoder:) ofClass:asClass arg:decoder];
        
        /* Set primary key */
        NSString * pkColumn = [asClass dbPKColumn];
        id pkValue = [decoder decodeObjectForColumn:pkColumn];
        [self setPrimaryKey:pkValue forObject:object asClass:asClass];
    }
    return object;
}

- (id) objectOfClass:(Class) objectClass fromDecoder:(DBCoder *) decoder{    
    return [self objectOfClass:objectClass withSchemeClass:objectClass fromDecoder:decoder];
}

- (id)objectWithId:(id)identifier andClass:(Class)objectClass withSchemeClass:(Class)asClass{
    
    if (!identifier) {
        NSLog(@"You are trying to fetch object of %@ class with nil id.",objectClass);
        return nil;
    }
    
    NSString * table = [asClass dbTable];
    NSString * primaryKey = [asClass dbPKColumn];
    
    NSString * query = [NSString stringWithFormat:@"SELECT * FROM %@ WHERE %@ = ?",table,primaryKey];
    
    NSArray * decoders = [self decodersFromSQLQuery:query withArgs:@[identifier]];
    
    id <DBCoding> object = nil;
    
    if ([decoders count] > 0){
        object = [self objectOfClass:objectClass withSchemeClass:asClass fromDecoder:decoders[0]];
    }
    
    return object;
}

- (id) objectWithId:(id) identifier andClass:(Class) objectClass{
    return [self objectWithId:identifier andClass:objectClass withSchemeClass:objectClass];
}

- (id) reloadObject:(id<DBCoding>) object{
    
    if (!object) {
        NSLog(@"Object to reload can't be nil");
        return nil;
    }
    
    id identifier = [(NSObject *)object valueForKey:[object dbPKProperty]];
    
    return [self objectWithId:identifier andClass:[object class]];
    
}

- (NSArray *) decodersFromSQLQuery:(NSString *) query withArgs:(NSArray *) args{
    
    if (!query) {
        NSLog(@"Query to fetch decoders can't be nil");
        return nil;
    }
    
    NSMutableArray * resultArray = [[NSMutableArray alloc] init];
   
    FMResultSet * resultSet = [self executeQuery:query withArgumentsInArray:args];
    
    while ([resultSet next]) {
        DBCoder * decoder = [[DBCoder alloc] initWithResultSet:resultSet dbService:self];
        [resultArray addObject:decoder];
    }
    
    [resultSet close];
    
    return resultArray;
}

- (id)latestPrimaryKeyForClass:(Class)objectClass{
    
    id primaryKey = nil;
    
    NSString * primaryKeyColumn = [objectClass dbPKColumn];
    NSString * tableName = [objectClass dbTable];
    NSString * query = [NSString stringWithFormat:@"SELECT %@ from %@ ORDER BY %@ DESC LIMIT 1",primaryKeyColumn,tableName,primaryKeyColumn];
    NSArray * decoders = [self decodersFromSQLQuery:query withArgs:nil];
    if (decoders.count > 0){
        primaryKey = [decoders[0] decodeObjectForColumn:primaryKeyColumn];
    }
    
    return primaryKey;
}

- (void) delete:(DBCoder *) coder mode:(DBMode) mode error: (NSError **) error{
    
    //Remove arrays of objects which refers to current
    if (mode & DBModeToMany){
        [coder enumerateToManyRelationCoders:^(DBCoder *connection_coder) {
            [connection_coder setPrimaryKey:[coder primaryKey]];
            [self delete:connection_coder mode:mode error:error];
        }];
    }
    //Remove object that refers to current
    if (mode & DBModeToOne){
        [coder enumerateToOneRelatedObjects:^id(id<DBCoding> object, __unsafe_unretained Class objectClass) {
            DBCoder * coder = [[DBCoder alloc] initWithDBObject:object as:objectClass];
            [self delete:coder mode:mode error:error];
            return nil;
        }];
    }
    
    if (!*error){
        [coder deleteStatement:^(NSString *query, NSArray *args) {
            BOOL success = NO;
            
            if (query && args){
                success = [self executeUpdate:query withArgumentsInArray:args];
            }
            
            if (error && !success){
                [self setupDBError:error action:@"deleting from db"];
            }
        }];
    }
}

- (void) deleteObject:(id<DBCoding>)object withSchemeClass:(Class) objectClass mode:(DBMode)mode completion:(DBDeleteCompletion)completion{
   
    NSError * error = nil;
    
    if (object){
        
        DBCoder * coder = [[DBCoder alloc] initWithDBObject:object as:objectClass];
        
        if ([self isExistCoder:coder]){
            [self delete:coder mode:mode error:&error];
        }else{
            error = [NSError errorWithCode:DBErrorCodeObjectIsNotExist description:@"Object not exist. Nothing to delete."];
        }
        
    }else{
        error = [NSError errorWithCode:DBErrorCodeObjectIsNil description:@"Object to delete can't be nil"];
    }
    
    if (completion) completion(error);
}

- (void) deleteObject:(id<DBCoding>) object mode:(DBMode) mode completion:(DBDeleteCompletion) completion{
    [self deleteObject:object withSchemeClass:[object class] mode:mode completion:completion];
}

@end



