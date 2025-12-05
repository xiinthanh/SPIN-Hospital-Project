#define TIME_LIMIT 480
#define N_SUBJECTS 20
#define N_CUSTOMER_MAX 20

#define N_OPERATING_ROOM 2

// 4 + 25 + 7 = 36
#define avgTreatmentTime_DeptC 36

mtype:messageType = { SUB, UNSUB, TICK, ACK };
mtype:customerType = { NORM, INS, VIP };
mtype:department = { A, B, C };


typedef Customer {
    int id;
    mtype:customerType type;
    mtype:department dept;
}

typedef WalkingCustomer {
    Customer customer;
    int minuteLeft;
}

int customerUniversalId = 0;

int globalTime = 0;

bool isClosed = false;


// Channel to send SUB/UNSUB request (along with _pid).
chan timeRegistration = [N_SUBJECTS] of { mtype:messageType, byte };

// Channel(s) to send TICK/ACK.
chan timeNotify[N_SUBJECTS] = [1] of { mtype:messageType };
chan timeReply[N_SUBJECTS] = [0] of { mtype:messageType };

chan customerEntrance = [10] of { Customer };
chan customerHallway = [10] of { Customer };

/*
Department C: 
- Time in Pre-OP Room [3-5]  
- Time in OP Room [20-30]
- Cleaning time [5-10] 
Minimum treatment time of department C: 3 + 20
Minimum cleaning time after each treatment: 5
There are 2 OP Room => Maximum 2 treatments at a time.
=> Maximum [ 480 / (3+20+5) ] x 2 = 32.28 clients per day
*/
chan deptQueue_C = [35] of { int, mtype:customerType };  // (customer id, customer type)
chan deptVIPQueue_C = [35] of { int };  // (customer id)

mtype:opRoomState = { CLEAN, DIRTY, BUSY };

int operatingRoomUniversalId = 0;
mtype:opRoomState opRoom[N_OPERATING_ROOM] = CLEAN;

int preOPCustomerID = 0;
mtype:customerType preOPCustomerType;
bool isPreOPReady = false;

int nWaitingCustomer_DeptC = 0;
bool isClosed_DeptC = false;


active proctype ClockTicking() {
    bool isSubscribed[N_SUBJECTS];
    mtype:messageType reqMsg;
    int reqId;
    int i;

    do 
        :: {
            // Check ALL pending registrations (SUB/UNSUB).
            do
                :: nempty(timeRegistration) -> {
                    timeRegistration ? reqMsg, reqId;
                    if
                        :: reqMsg == SUB -> isSubscribed[reqId] = true;
                        :: reqMsg == UNSUB -> isSubscribed[reqId] = false;
                    fi
                }
                :: empty(timeRegistration) -> break;
            od

            // Call subscribed subjects to perform their tasks.
            for (i : 0 .. N_SUBJECTS-1) {
                if
                    :: isSubscribed[i] -> timeNotify[i] ! TICK;
                    :: else -> skip;
                fi
            }

            // Wait for subscribed subjects to finish their tasks.
            for (i : 0 .. N_SUBJECTS-1) {
                if
                    :: isSubscribed[i] -> timeReply[i] ? ACK;
                    :: else -> skip;
                fi
            }

            // Increment the time.
            globalTime++;
            // printf("%d\n", globalTime);
            if
                :: globalTime == TIME_LIMIT -> isClosed = true;
                :: else -> skip;
            fi

            // Working over time: treatment takes longer than expected.
            if 
                :: isClosed && _nr_pr == 1 -> {  // Stop when it is the only process left.
                    break;
                }
                :: else -> skip;
            fi
        }
    od
}

/*
+ 40% new normal customer
+ 20% new insurance customer
+ 10% new VIP
+ 30% no new customer
*/
active[3] proctype CustomerEntranceQueue() {
    Customer newCustomer;
    bool isSkip;

    do
        :: isClosed -> break;
        :: !isClosed -> {
            isSkip = false;
            // Randomly select customer's type.
            if
                :: 1 -> newCustomer.type = NORM;
                :: 2 -> newCustomer.type = NORM;
                :: 3 -> newCustomer.type = NORM;
                :: 4 -> newCustomer.type = NORM;
                :: 5 -> newCustomer.type = INS;
                :: 6 -> newCustomer.type = INS;
                :: 7 -> newCustomer.type = VIP;
                :: 8 -> isSkip = true;
                :: 9 -> isSkip = true;
                :: 10 -> isSkip = true;
            fi

            if
                :: !isSkip -> {
                    // Get new customer id.
                    atomic {
                        newCustomer.id = customerUniversalId;
                        customerUniversalId++;
                    }

                    // Randomly select customer's department.
                    if
                        :: 1 -> newCustomer.dept = A;
                        :: 2 -> newCustomer.dept = B;
                        :: 3 -> newCustomer.dept = C;
                    fi

                    // Add new customer to the queue
                    customerEntrance ! newCustomer;
                }
                :: else -> skip;
            fi
        }
    od
}


active proctype GateKeeper() {
    int processingTime;
    Customer processingCustomer;
    do
        :: {
            // Non-critical: Wait for the next customer.
            if
                :: customerEntrance ? processingCustomer -> skip;
                :: isClosed && empty(customerEntrance) -> break;  // CLOSED.
            fi

            // Checking customer takes randomly 1-5 minutes.
            select (processingTime: 1 .. 5);

            // Register to the ClockTicking.
            timeRegistration ! SUB, _pid;


            // Critical: checking customer's type & department.
            // (sync with Global Time)
            do
                :: timeNotify[_pid] ? TICK -> {
                    processingTime--;
                    
                    if
                        :: processingTime == 0 -> {
                            // Done checking => proceed to decide accept/reject.
                            if 
                                :: processingCustomer.dept == A -> {
                                    // TODO
                                    skip;
                                }
                                :: processingCustomer.dept == B -> {
                                    // TODO
                                    skip;
                                }
                                :: processingCustomer.dept == C -> {  // Checking rejection for department C
                                    if
                                        :: globalTime <= TIME_LIMIT - (nWaitingCustomer_DeptC + 1) * avgTreatmentTime_DeptC -> {
                                            customerHallway ! processingCustomer;
                                            nWaitingCustomer_DeptC++;
                                        }
                                        :: else -> {  // Reject
                                            isClosed_DeptC = true;
                                        }
                                    fi
                                }
                            fi

                            // Unregister to the ClockTicking.
                            timeRegistration ! UNSUB, _pid;
                            
                            timeReply[_pid] ! ACK;
                            break;
                        }
                        :: else -> skip;
                    fi

                    timeReply[_pid] ! ACK;
                }
            od

            if
                :: isClosed && empty(customerEntrance) -> break;
                :: !isClosed || nempty(customerEntrance) -> skip;
            fi
        }
    od
}

// Always countdown for every minutes.
active proctype HallWay() {
    WalkingCustomer walkCus[N_CUSTOMER_MAX];
    int index;
    int i, j;

    timeRegistration ! SUB, _pid;
    do
        :: timeNotify[_pid] ? TICK -> {
            // Adding new entered customers.
            do
                :: nempty(customerHallway) -> {
                    customerHallway ? walkCus[index].customer;

                    // Walking time is randomly 1-5 minutes long.
                    int walkingTime;
                    select (walkingTime: 1 .. 5);
                    walkCus[index].minuteLeft = walkingTime;

                    index++;       

                    assert(index < N_CUSTOMER_MAX);
                }
                :: empty(customerHallway) -> break;
            od

            // Decrease minuteLeft for each walking customer.
            i = 0;
            do
                :: i >= index -> break;
                :: i < index -> {
                    walkCus[i].minuteLeft--;
                    if
                        :: walkCus[i].minuteLeft == 0 -> {
                            // walkCus[i] has done walking => move to Department Queue.
                            if
                                :: walkCus[i].customer.dept == A -> {
                                    // TODO
                                    skip;
                                }
                                :: walkCus[i].customer.dept == B -> {
                                    // TODO
                                    skip;
                                }
                                :: walkCus[i].customer.dept == C -> {
                                    if
                                        :: walkCus[i].customer.type == VIP -> {
                                            deptVIPQueue_C ! walkCus[i].customer.id;
                                        }
                                        :: else -> {  // INS + NORM
                                            int tempId = walkCus[i].customer.id;
                                            mtype:customerType tempType = walkCus[i].customer.type;
                                            deptQueue_C ! tempId, tempType;
                                        }
                                    fi
                                }
                            fi  


                            // Remove walkCus[i] from the array (shifting to left).
                            for (j : i .. index-2) {
                                walkCus[j].customer.id = walkCus[j + 1].customer.id;
                                walkCus[j].customer.type = walkCus[j + 1].customer.type;
                                walkCus[j].customer.dept = walkCus[j + 1].customer.dept;
                                
                                walkCus[j].minuteLeft = walkCus[j + 1].minuteLeft;
                            }
                            index--;  // Number of walking customers is decreasing by 1.
                            i--;  // Do not pass the new walkCus[i].
                        }
                        :: else -> skip;
                    fi
                    i++;
                }
            od

            if
                :: isClosed && index == 0 -> {
                    // Unsubscribe to the TimeTicking.
                    timeRegistration ! UNSUB, _pid;
                }
                :: else -> skip;
            fi

            timeReply[_pid] ! ACK;

            if
                :: isClosed && index == 0 -> break;
                :: else -> skip;
            fi
        }
    od
}



active proctype PreOPRoom() {
    int preOPTime;
    bool isPreselected = false;

    do
        :: {
            if
                :: isPreselected -> skip;
                :: else -> {
                    // Waiting for patient to enter.
                    if
                        :: deptVIPQueue_C ? preOPCustomerID; -> {  // Select the next VIP customer.
                            preOPCustomerType = VIP;
                        }
                        :: deptQueue_C ? preOPCustomerID, preOPCustomerType -> skip;  // Select the next customer in the queue.
                        :: deptQueue_C ?? preOPCustomerID, INS -> skip;  // Select the next INS customer in the queue.

                        :: isClosed && nWaitingCustomer_DeptC == 0 -> break;  // CLOSED.
                    fi
                }
            fi
            isPreselected = false;
            // Staying time is randomly selected from 3-5 minutes.
            select (preOPTime: 3 .. 5);
        
            // Begin the countdown. 
            timeRegistration ! SUB, _pid;

            do
                :: timeNotify[_pid] ? TICK -> {
                    preOPTime--;
                    if
                        :: preOPTime == 0 -> {
                            // Done => Ready for Operating Room.
                            isPreOPReady = true;

                            // Unregister to the ClockTicking.
                            timeRegistration ! UNSUB, _pid;
                            timeReply[_pid] ! ACK;
                            break;
                        }
                        :: else -> skip;
                    fi

                    // Check if the current customer is kicked out or not.
                    if
                        :: preOPCustomerType != VIP -> {
                            if 
                                :: nempty(deptVIPQueue_C) -> {
                                    int vipId;
                                    deptVIPQueue_C ? vipId 
                                    
                                    // The current customer is kicked out of the Pre-OP room.
                                    deptQueue_C ! preOPCustomerID, preOPCustomerType;  // Requeue the current customer.
                                    
                                    // The next customer is a VIP.
                                    isPreselected = true;
                                    preOPCustomerID = vipId;
                                    preOPCustomerType = VIP;
                                    
                                    // End the countdown.
                                    timeRegistration ! UNSUB, _pid;
                                    timeReply[_pid] ! ACK;
                                    break;
                                }
                                :: empty(deptVIPQueue_C) -> skip;  // There is no VIP atm.
                            fi
                        }
                        :: else -> skip;  // VIP cannot be kicked.
                    fi

                    timeReply[_pid] ! ACK;
                }
            od

            // Waiting for Operating Room, but there is still a risk of being kicked out.
            do
                :: atomic {
                    if
                        :: !isPreOPReady -> break;  // Not waiting anymore.
                        :: isPreOPReady -> {
                            // Check if the current customer is kicked out or not.
                            if
                                :: preOPCustomerType != VIP -> {  
                                    if 
                                        :: nempty(deptVIPQueue_C) -> {
                                            int vipId;
                                            deptVIPQueue_C ? vipId 
                                            
                                            // The current customer is kicked out of the Pre-OP room.
                                            deptQueue_C ! preOPCustomerID, preOPCustomerType;  // Requeue the current customer.
                                            
                                            // The next customer is a VIP.
                                            isPreselected = true;
                                            preOPCustomerID = vipId;
                                            preOPCustomerType = VIP;

                                            isPreOPReady = false;
                                        }
                                        :: empty(deptVIPQueue_C) -> skip;  // There is no VIP atm.
                                    fi
                                }
                                :: else -> skip;  // VIP cannot be kicked.
                            fi
                        }
                    fi
                } 
            od
        }
    od
}

active[2] proctype OperatingRoom() {
    int opRoomId;
    atomic {
        opRoomId = operatingRoomUniversalId;
        operatingRoomUniversalId++;
    }

    int currentCustomerId;
    mtype:customerType currentCustomerType;
    int operatingTime;

    do
        :: {
            // Wait for customer ready in Pre-OP room and this OP room to be CLEAN.
            atomic {
                if
                    :: ( opRoom[opRoomId] == CLEAN ) && ( isPreOPReady == true ) -> {
                        currentCustomerId = preOPCustomerID;
                        currentCustomerType = preOPCustomerType;
                        isPreOPReady = false;
                    }
                    :: isClosed && nWaitingCustomer_DeptC == 0 -> break;  // CLOSED.
                fi
            }

            // Surgery time is random from 20 to 30.
            select (operatingTime: 20 .. 30);

            // Start the countdown: performing surgery.
            opRoom[opRoomId] = BUSY;
            timeRegistration ! SUB, _pid;
            do
                :: timeNotify[_pid] ? TICK -> {
                    operatingTime--;
                    if
                        :: operatingTime == 0 -> { 
                            // Surgery completed.
                            opRoom[opRoomId] = DIRTY;
                            nWaitingCustomer_DeptC--;
                            
                            // Unregister to the ClockTicking.
                            timeRegistration ! UNSUB, _pid;
                            timeReply[_pid] ! ACK;
                            break;                            
                        }
                        :: else -> skip;
                    fi

                    timeReply[_pid] ! ACK;
                }
            od
        }
    od
}

active proctype CleaningTeam() {
    int cleaningTime;
    int cleaningRoomId;
    do
        :: {
            // Wait for any of the two room to be DIRTY.
            if
                :: opRoom[0] == DIRTY -> cleaningRoomId = 0;
                :: opRoom[1] == DIRTY -> cleaningRoomId = 1;
                :: isClosed && opRoom[0] != DIRTY && opRoom[1] != DIRTY && nWaitingCustomer_DeptC == 0 -> {  // CLOSED
                    break;
                }
            fi

            // Cleaning time is random from 5 to 10 minutes
            select (cleaningTime: 5 .. 10);
            
            // Start the countdown: cleaning the DIRTY room.
            timeRegistration ! SUB, _pid;

            do
                :: timeNotify[_pid] ? TICK -> {
                    cleaningTime--;
                    if
                        :: cleaningTime == 0 -> {
                            // Done cleaning => Room is clean.
                            opRoom[cleaningRoomId] = CLEAN;

                            // Unregister & break.
                            timeRegistration ! UNSUB, _pid;
                            timeReply[_pid] ! ACK;
                            break;
                        }
                        :: else -> skip;
                    fi

                    timeReply[_pid] ! ACK;
                }
            od
        }
    od
}