// --- SYSTEM CONSTANTS & CONFIGURATION ---
#define TIME_LIMIT 480
#define MAX_PROCESSES 20  // TODO: Changed base on the number of process
#define N_CUSTOMER_MAX 20

// --- DEPARTMENT A CONFIGURATION ---
#define N_DOCTOR_A 3
#define N_MACHINE_A 2
#define avgTreatmentTime_DeptA 15 /* Average of 10-20 mins */
#define avgParallelTreatmentTime_DeptA 7  /* 15/2 = 7.5 minutes per customer with 3 doctors & 2 machines */

// Dept B: Exam (4) + Treatment (12.5 to 17.5) ~ 20 (safe margin)
#define avgTreatmentTime_DeptB 20
#define avgParallelTreatmentTime_DeptB 7  /* 20 / 3 = 6.667 minutes per customer with 2 juniors & 1 senior */

// --- DEPARTMENT C CONFIGURATION ---
#define N_OPERATING_ROOM 2
// 4 (PreOp) + 25 (Surgery) + 7 (Cleaning) = 36
#define avgTreatmentTime_DeptC 36
// FIXED: Adjusted for parallel processing (2 operating rooms)
#define avgParallelTreatmentTime_DeptC 18  /* 36/2 = 18 minutes per customer with 2 rooms */

// --- TYPES & ENUMS ---
mtype:messageType = { SUB, UNSUB, TICK, ACK };
mtype:customerType = { NORM, INS, VIP };
mtype:department = { A, B, C };
mtype:opRoomState = { CLEAN, DIRTY, BUSY };

typedef Customer {
    byte id;
    mtype:customerType type;
    mtype:department dept;
}

typedef WalkingCustomer {
    Customer customer;
    byte minuteLeft;
}

// --- GLOBAL VARIABLES & CHANNELS ---
byte customerUniversalId = 0;
int globalTime = 0;
bool isClosed = false;

// Channels to send SUB/UNSUB request for time synchronization.
chan timeRegistration = [MAX_PROCESSES] of { mtype:messageType, chan };

// Entrance & Hallway Channels
chan customerEntrance = [3] of { Customer };
chan customerHallway = [10] of { Customer };



// --- DEPARTMENT A GLOBALS ---
chan deptQueue_A = [10] of { byte, mtype:customerType };
chan deptVIPQueue_A = [10] of { byte };
byte machinesAvailable = N_MACHINE_A; 
byte nWaitingCustomer_DeptA = 0;
byte nProcessingCustomer_DeptA = 0;


/*
Department B Channels:
- Junior Queue High Priority (Insured)
- Junior Queue Low Priority (Normal)
- Senior Queue (VIP + Referrals)
*/
chan deptQueue_B_Junior_INS = [10] of { byte }; 
chan deptQueue_B_Junior_NORM = [10] of { byte };
chan deptQueue_B_Senior = [10] of { byte, bool }; // ID, isReferral (true=referral, false=direct VIP)

// Variables for Dept B rejection rule
byte nWaitingCustomer_DeptB = 0;
bool isClosed_DeptB = false;



// --- DEPARTMENT C GLOBALS ---
chan deptQueue_C = [10] of { byte, mtype:customerType };
chan deptVIPQueue_C = [10] of { byte };

byte operatingRoomUniversalId = 0;
mtype:opRoomState opRoom[N_OPERATING_ROOM] = CLEAN;
byte preOPCustomerID = 0;
mtype:customerType preOPCustomerType;
bool isPreOPReady = false;

byte nWaitingCustomer_DeptC = 0;
byte nProcessingCustomer_DeptC = 0;


// --- PROCESS: CLOCK TICKING (THE HEARTBEAT) ---
active proctype ClockTicking() {
    chan subscribers[MAX_PROCESSES];
    byte nSubscribers = 0;
    mtype:messageType reqMsg;
    chan reqChan;
    byte i;
    
    do 
    :: {
        // 1. Process Registrations: check pending registrations (SUB/UNSUB).
        do
            :: nempty(timeRegistration) -> {
                timeRegistration ? reqMsg, reqChan;
                if
                    :: reqMsg == SUB -> {
                        subscribers[nSubscribers] = reqChan;
                        nSubscribers++;
                        assert(nSubscribers <= MAX_PROCESSES);
                    }
                    :: reqMsg == UNSUB -> {
                        // Remove from subscriber list
                        i = 0;
                        do
                            :: i >= nSubscribers -> break;
                            :: i < nSubscribers -> {
                                if
                                    :: subscribers[i] == reqChan -> {
                                        // Shift remaining subscribers
                                        byte j;
                                        for (j : i .. nSubscribers-2) {
                                            subscribers[j] = subscribers[j+1];
                                        }
                                        nSubscribers--;
                                        break;
                                    }
                                    :: else -> i++;
                                fi
                            }
                        od
                    }
                fi
            }
            :: empty(timeRegistration) -> break;
        od

        // 2. Broadcast TICK to all subscribers: call subscribed subjects to perform their tasks.
        for (i : 0 .. nSubscribers-1) {
            subscribers[i] ! TICK;
        }

        // 3. Wait for all ACKs
        for (i : 0 .. nSubscribers-1) {
            subscribers[i] ? ACK;
        }

        // 4. Advance Time
        globalTime++;
        if
            :: globalTime == TIME_LIMIT -> isClosed = true;
            :: else -> skip;
        fi

        // Working over time: treatment takes longer than expected.
        if 
            :: isClosed && 
               nWaitingCustomer_DeptA == 0 && nProcessingCustomer_DeptA == 0 &&
               nWaitingCustomer_DeptC == 0 && nProcessingCustomer_DeptC == 0 &&
               nSubscribers == 0 -> break;
            :: else -> skip;
        fi
    }
    od
}

// --- PROCESS: CUSTOMER ENTRANCE (GENERATOR) ---
active[3] proctype CustomerEntranceQueue() {
    Customer newCustomer;
    bool isSkip;

    do
        :: isClosed -> break;
        :: !isClosed -> {
            isSkip = false;
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

// --- PROCESS: GATEKEEPER (ADMISSION CONTROL) ---
active proctype GateKeeper() {
    chan myChan = [1] of { mtype:messageType };
    byte processingTime;
    Customer processingCustomer;
    
    do
        :: {
            if
                :: customerEntrance ? processingCustomer -> skip;
                :: empty(customerEntrance) && isClosed -> break;  // CLOSED.
            fi

            select (processingTime: 1 .. 5);
            timeRegistration ! SUB, myChan;

            // (sync with Global Time)
            do
                :: myChan ? TICK -> {
                    processingTime--;

                    if
                        :: processingTime == 0 -> {
                            if 
                                :: processingCustomer.dept == A && !isClosed -> {
                                    // Done checking => proceed to decide accept/reject.
                                    if
                                        :: globalTime <= TIME_LIMIT - (nWaitingCustomer_DeptA + 1) * avgParallelTreatmentTime_DeptA -> {
                                            customerHallway ! processingCustomer;
                                            nWaitingCustomer_DeptA++;
                                        }
                                        :: else -> skip;  // Reject customer
                                    fi
                                }
                                :: processingCustomer.dept == B && !isClosed -> {
                                    // Department B Admission with Rejection Rule
                                    if
                                        :: globalTime <= TIME_LIMIT - (nWaitingCustomer_DeptB + 1) * avgParallelTreatmentTime_DeptB -> {
                                            customerHallway ! processingCustomer;
                                            nWaitingCustomer_DeptB++;
                                        }
                                        :: else -> skip;
                                    fi
                                }
                                :: processingCustomer.dept == C && !isClosed -> {
                                    // FIXED: Account for parallel processing
                                    if
                                        :: globalTime <= TIME_LIMIT - (nWaitingCustomer_DeptC + 1) * avgParallelTreatmentTime_DeptC -> {
                                            customerHallway ! processingCustomer;
                                            nWaitingCustomer_DeptC++;
                                        }
                                        :: else -> skip;  // Reject customer
                                    fi
                                }
                                :: else -> skip;  // After closure, reject all new admissions
                            fi

                            timeRegistration ! UNSUB, myChan;
                            myChan ! ACK;
                            break;
                        }
                        :: else -> skip;
                    fi
                    myChan ! ACK;
                }
            od
        }
    od
}

// --- PROCESS: HALLWAY (ROUTING) ---
active proctype HallWay() {
    chan myChan = [1] of { mtype:messageType };
    WalkingCustomer walkCus[N_CUSTOMER_MAX];
    byte index;
    int i, j;

    timeRegistration ! SUB, myChan;
    do
        :: myChan ? TICK -> {
            // 1. Accept new customers from GateKeeper
            do
                :: nempty(customerHallway) -> {
                    customerHallway ? walkCus[index].customer;

                    // Walking time is randomly 1-5 minutes long.
                    byte walkingTime;
                    select (walkingTime: 1 .. 5);
                    walkCus[index].minuteLeft = walkingTime;

                    index++;
                    assert(index < N_CUSTOMER_MAX);
                }
                :: empty(customerHallway) -> break;
            od

            // 2. Process walking customers
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
                                    if
                                        :: walkCus[i].customer.type == VIP -> {
                                            deptVIPQueue_A ! walkCus[i].customer.id;
                                        }
                                        :: else -> {
                                            deptQueue_A ! walkCus[i].customer.id, walkCus[i].customer.type;
                                        }
                                    fi
                                }
                                :: walkCus[i].customer.dept == B -> {
                                    if
                                        :: walkCus[i].customer.type == VIP -> {
                                            // VIP goes directly to Senior
                                            deptQueue_B_Senior ! walkCus[i].customer.id, false;
                                        }
                                        :: walkCus[i].customer.type == INS -> {
                                            // Insured goes to High Priority Junior Queue
                                            deptQueue_B_Junior_INS ! walkCus[i].customer.id;
                                        }
                                        :: else -> { 
                                            // Normal goes to Low Priority Junior Queue
                                            deptQueue_B_Junior_NORM ! walkCus[i].customer.id;
                                        }
                                    fi
                                }
                                :: walkCus[i].customer.dept == C -> {
                                    if
                                        :: walkCus[i].customer.type == VIP -> {
                                            deptVIPQueue_C ! walkCus[i].customer.id;
                                        }
                                        :: else -> {  // INS + NORM
                                            byte tempId = walkCus[i].customer.id;
                                            mtype:customerType tempType = walkCus[i].customer.type;
                                            deptQueue_C ! tempId, tempType;
                                        }
                                    fi
                                }
                            fi

                            // Remove from array
                            for (j : i .. index-2) {
                                walkCus[j].customer.id = walkCus[j + 1].customer.id;
                                walkCus[j].customer.type = walkCus[j + 1].customer.type;
                                walkCus[j].customer.dept = walkCus[j + 1].customer.dept;
                                
                                walkCus[j].minuteLeft = walkCus[j + 1].minuteLeft;
                            }
                            index--;  // Number of walking customers is decreasing by 1.
                            i--;  // // Do not pass the new walkCus[i].
                        }
                        :: else -> skip;
                    fi
                    i++;
                }
            od

            if
                :: isClosed && index == 0 && empty(customerHallway) -> {
                    timeRegistration ! UNSUB, myChan;
                }
                :: !isClosed || index != 0 || nempty(customerHallway) -> skip;
            fi

            myChan ! ACK;
            
            if
                :: isClosed && index == 0 && empty(customerHallway) -> break;
                :: !isClosed || index != 0 || nempty(customerHallway) -> skip;
            fi
        }
    od
}



/* --- DEPARTMENT B LOGIC --- */

active[2] proctype DeptB_Junior() {
    chan myChan = [1] of { mtype:messageType };
    byte customerId;
    byte examTime;
    byte treatTime;
    bool isSevere;
    
    do
        :: {
            // Wait for customer (Priority: INS > NORM)
            if
                :: nempty(deptQueue_B_Junior_INS) -> {
                    deptQueue_B_Junior_INS ? customerId;
                }
                :: nempty(deptQueue_B_Junior_NORM) && empty(deptQueue_B_Junior_INS) -> {
                    deptQueue_B_Junior_NORM ? customerId;
                }
                :: isClosed && empty(deptQueue_B_Junior_INS) && empty(deptQueue_B_Junior_NORM) -> break; 
            fi
            
            // 1. Examination Phase (3-5 minutes)
            select(examTime : 3..5);
            timeRegistration ! SUB, myChan;
            
            do
                :: myChan ? TICK -> {
                    examTime--;
                    if
                    :: examTime == 0 -> {
                        timeRegistration ! UNSUB, myChan;

                        myChan ! ACK;
                        break;
                    }
                    :: else -> {
                        myChan ! ACK;
                    }
                    fi
                }
            od
            
            // 2. Decision Phase (Mild vs Severe)
            if
                :: 1 -> isSevere = false; // Mild
                :: 1 -> isSevere = true;  // Severe
            fi
            
            if
                :: isSevere -> {
                    // Refer to Senior (isReferral = true)
                    deptQueue_B_Senior ! customerId, true; 
                    // Note: Patient is still in Dept B, so we DO NOT decrement nWaitingCustomer_DeptB yet.
                }
                :: !isSevere -> {
                    // Treat Mild Case (10-15 minutes)
                    select(treatTime : 10..15);
                    
                    timeRegistration ! SUB, myChan;

                    do
                        :: myChan ? TICK -> {
                            treatTime--;
                            if
                                :: treatTime == 0 -> {
                                    // Treatment finished -> Patient leaves Dept B
                                    nWaitingCustomer_DeptB--;
                                    
                                    timeRegistration ! UNSUB, myChan;
                                    myChan ! ACK;
                                    break;
                                }
                                :: else -> {
                                    myChan ! ACK;
                                }
                            fi
                        }
                    od
                }
            fi
        }
    od
}

active proctype DeptB_Senior() {
    chan myChan = [1] of { mtype:messageType };
    byte customerId;
    bool isReferral;
    byte treatTime;
    
    byte treatTimeSave;
    
    do
        :: {
            // Wait for customer
            if
                :: deptQueue_B_Senior ? customerId, isReferral -> skip;
                :: isClosed && empty(deptQueue_B_Senior) -> break;
            fi
            
            // Determine Treatment Time
            if
                :: isReferral -> {
                    // Referred case: 10-15 minutes
                    select(treatTime : 10..15);
                }
                :: !isReferral -> {
                    // VIP or Unchecked: 15-20 minutes
                    select(treatTime : 15..20);
                }
            fi
            treatTimeSave = treatTime;
            // Perform Treatment
            timeRegistration ! SUB, myChan;
            do
                :: myChan ? TICK -> {
                    treatTime--;
                    if
                        :: treatTime == 0 -> {
                            // Treatment finished -> Patient leaves Dept B
                            nWaitingCustomer_DeptB--;
                            
                            printf("\nB - Customer with id %d is treated in %d minutes.\n", customerId, treatTimeSave);
                            
                            timeRegistration ! UNSUB, myChan;
                            myChan ! ACK;
                            break;
                        }
                        :: else -> {
                            myChan ! ACK;
                        }
                    fi
                }
            od
        }
    od
}

/* --- END DEPARTMENT B LOGIC --- */



// // --- PROCESS: DEPARTMENT A DOCTORS ---
// active [3] proctype DoctorA() {
//     chan myChan = [1] of { mtype:messageType };
//     byte patientId;
//     mtype:customerType pType;
//     byte treatTime;

//     do
//     :: {
//         if
//             :: isClosed && nWaitingCustomer_DeptA == 0 && 
//                empty(deptVIPQueue_A) && empty(deptQueue_A) -> break;
//             :: else -> skip;
//         fi

//         // Wait for Patient AND Machine
//         atomic {
//             if
//             :: machinesAvailable > 0 && nempty(deptVIPQueue_A) -> {
//                 machinesAvailable--;
//                 deptVIPQueue_A ? patientId;
//                 pType = VIP;
//                 nWaitingCustomer_DeptA--;
//                 nProcessingCustomer_DeptA++;
//             }
//             :: machinesAvailable > 0 && empty(deptVIPQueue_A) && 
//                deptQueue_A ?? [patientId, INS] -> {
//                 machinesAvailable--;
//                 deptQueue_A ? patientId, INS;  // FIXED: Use ? instead of ??
//                 pType = INS;
//                 nWaitingCustomer_DeptA--;
//                 nProcessingCustomer_DeptA++;
//             }
//             :: machinesAvailable > 0 && empty(deptVIPQueue_A) && 
//                !deptQueue_A ?? [patientId, INS] && nempty(deptQueue_A) -> {
//                 machinesAvailable--;
//                 deptQueue_A ? patientId, pType;
//                 nWaitingCustomer_DeptA--;
//                 nProcessingCustomer_DeptA++;
//             }
//             :: else -> skip;  // No patient or machine available
//             fi
//         }

//         // Only proceed if we got a patient
//         if
//             :: nProcessingCustomer_DeptA > 0 && 
//                (pType == VIP || pType == INS || pType == NORM) -> {
//                 // Treatment
//                 select(treatTime: 10..20);
//                 timeRegistration ! SUB, myChan;
                
//                 do
//                 :: globalTick ? TICK -> {
//                     treatTime--;
//                     if
//                     :: treatTime == 0 -> {
//                         machinesAvailable++;
//                         nProcessingCustomer_DeptA--;
//                         timeRegistration ! UNSUB, myChan;
//                         myChan ! ACK;
//                         break;
//                     }
//                     :: else -> skip;
//                     fi
//                     myChan ! ACK;
//                 }
//                 od
//             }
//             :: else -> skip;
//         fi
//     }
//     od
// }

// --- PROCESS: DEPARTMENT C PRE-OP ---
active proctype PreOPRoom() {
    chan myChan = [1] of { mtype:messageType };
    byte preOPTime;

    do
        :: {
            if
                :: isClosed && nWaitingCustomer_DeptC == 0 &&
                   empty(deptVIPQueue_C) && empty(deptQueue_C) -> break;
                :: else -> skip;
            fi

            // Select patient
            if
                :: nempty(deptVIPQueue_C) -> {
                    deptVIPQueue_C ? preOPCustomerID;
                    preOPCustomerType = VIP;
                    nWaitingCustomer_DeptC--;
                }
                :: empty(deptVIPQueue_C) && deptQueue_C ?? [preOPCustomerID, INS] -> {
                    deptQueue_C ? preOPCustomerID, INS;  // FIXED: Proper receive
                    preOPCustomerType = INS;
                    nWaitingCustomer_DeptC--;
                }
                :: empty(deptVIPQueue_C) && !deptQueue_C ?? [preOPCustomerID, INS] && 
                   nempty(deptQueue_C) -> {
                    deptQueue_C ? preOPCustomerID, preOPCustomerType;
                    nWaitingCustomer_DeptC--;
                }
                :: else -> skip;  // No patient available
            fi

            // Only proceed if we got a patient
            if
                :: preOPCustomerType == VIP || preOPCustomerType == INS || 
                   preOPCustomerType == NORM -> {
                    select (preOPTime: 3 .. 5);
                    nProcessingCustomer_DeptC++;
                    timeRegistration ! SUB, myChan;

                    do
                        :: globalTick ? TICK -> {
                            preOPTime--;
                            if
                                :: preOPTime == 0 -> {
                                    isPreOPReady = true;
                                    timeRegistration ! UNSUB, myChan;
                                    myChan ! ACK;
                                    break;
                                }
                                :: else -> skip;
                            fi

                            // Kick logic for VIP
                            if
                                :: preOPCustomerType != VIP && nempty(deptVIPQueue_C) -> {
                                    byte vipId;
                                    deptVIPQueue_C ? vipId;
                                    // Kick current back
                                    deptQueue_C ! preOPCustomerID, preOPCustomerType;
                                    nWaitingCustomer_DeptC++;
                                    // Accept VIP
                                    preOPCustomerID = vipId;
                                    preOPCustomerType = VIP;
                                    preOPTime = 0;  // Restart prep for VIP
                                }
                                :: else -> skip;
                            fi
                            myChan ! ACK;
                        }
                    od

                    // Wait for OR to pick up patient
                    do
                        :: !isPreOPReady -> break;
                        :: isPreOPReady -> {
                            // Can still be kicked while waiting
                            if
                                :: preOPCustomerType != VIP && nempty(deptVIPQueue_C) -> {
                                    byte vipId;
                                    deptVIPQueue_C ? vipId;
                                    deptQueue_C ! preOPCustomerID, preOPCustomerType;
                                    nWaitingCustomer_DeptC++;
                                    preOPCustomerID = vipId;
                                    preOPCustomerType = VIP;
                                    isPreOPReady = false;
                                    break;
                                }
                                :: else -> skip;
                            fi
                        }
                    od
                }
                :: else -> skip;
            fi
        }
    od
}

// --- PROCESS: DEPARTMENT C OPERATING ROOM ---
active[2] proctype OperatingRoom() {
    chan myChan = [1] of { mtype:messageType };
    byte opRoomId;
    atomic {
        opRoomId = operatingRoomUniversalId;
        operatingRoomUniversalId++;
    }

    byte currentCustomerId;
    mtype:customerType currentCustomerType;
    byte operatingTime;
    byte operatingTimeSave;

    do
        :: {
            atomic {
                if
                    :: opRoom[opRoomId] == CLEAN && isPreOPReady -> {
                        currentCustomerId = preOPCustomerID;
                        currentCustomerType = preOPCustomerType;
                        isPreOPReady = false;
                        opRoom[opRoomId] = BUSY;
                    }
                    :: isClosed && nProcessingCustomer_DeptC == 0 && !isPreOPReady -> break;
                fi
            }

            // Surgery time is random from 20 to 30.
            select (operatingTime: 20 .. 30);
            operatingTimeSave = operatingTime;

            // Start the countdown: performing surgery.
            opRoom[opRoomId] = BUSY;
            timeRegistration ! SUB, _pid;
            do
                :: myChan ? TICK -> {
                    operatingTime--;
                    if
                        :: operatingTime == 0 -> { 
                            // Surgery completed.
                            opRoom[opRoomId] = DIRTY;
                            nProcessingCustomer_DeptC--;

                            printf("\nC - Customer with id %d is treated in %d minutes.\n", currentCustomerId, operatingTimeSave);
                            
                            // Unregister to the ClockTicking.
                            timeRegistration ! UNSUB, myChan;
                            myChan ! ACK;
                            break;                            
                        }
                        :: else -> skip;
                    fi

                    myChan ! ACK;
                }
            fi
        }
    od
}

// --- PROCESS: DEPARTMENT C CLEANING TEAM ---
active proctype CleaningTeam() {
    chan myChan = [1] of { mtype:messageType };
    byte cleaningTime;
    byte cleaningRoomId;
    
    do
        :: {
            if
                :: opRoom[0] == DIRTY -> cleaningRoomId = 0;
                :: opRoom[1] == DIRTY -> cleaningRoomId = 1;
                :: isClosed && opRoom[0] != DIRTY && opRoom[1] != DIRTY && 
                   nProcessingCustomer_DeptC == 0 -> break;
            fi

            // Cleaning time is random from 5 to 10 minutes
            select (cleaningTime: 5 .. 10);
            
            // Start the countdown: cleaning the DIRTY room.
            timeRegistration ! SUB, myChan;

            do
                :: myChan ? TICK -> {
                    cleaningTime--;
                    if
                        :: cleaningTime == 0 -> {
                            // Done cleaning => Room is clean.
                            opRoom[cleaningRoomId] = CLEAN;

                            // Unregister & break.
                            timeRegistration ! UNSUB, myChan;
                            myChan ! ACK;
                            break;
                        }
                        :: else -> skip;
                    fi

                    myChan ! ACK;
                }
            od
        }
    od
}