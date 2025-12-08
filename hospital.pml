// --- SYSTEM CONSTANTS & CONFIGURATION ---
#define TIME_LIMIT 480
#define MAX_PROCESSES 15  // FIXED: Accurate count of all processes
#define N_CUSTOMER_MAX 20

// --- DEPARTMENT A CONFIGURATION ---
#define N_DOCTOR_A 3
#define N_MACHINE_A 2
#define avgTreatmentTime_DeptA 15 /* Average of 10-20 mins */
// FIXED: Adjusted for parallel processing (3 doctors)
#define avgParallelTreatmentTime_DeptA 5  /* 15/3 = 5 minutes per customer with 3 doctors */

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

// FIXED: Time Synchronization with proper sizing
chan timeRegistration = [MAX_PROCESSES] of { mtype:messageType, chan };
chan globalTick = [MAX_PROCESSES] of { mtype:messageType };

// Entrance & Hallway Channels
chan customerEntrance = [10] of { Customer };
chan customerHallway = [10] of { Customer };

// --- DEPARTMENT A GLOBALS ---
chan deptNormQueue_A = [10] of { byte };
chan deptInsQueue_A = [10] of { byte };
chan deptVIPQueue_A = [10] of { byte };
byte machinesAvailable = N_MACHINE_A; 
byte nWaitingCustomer_DeptA = 0;
byte nProcessingCustomer_DeptA = 0;
// Machine reservation system to prevent starvation
bool machineReserved[N_MACHINE_A] = false;
byte machineReservedBy[N_MACHINE_A] = 255;  // 255 = no reservation

// --- DEPARTMENT C GLOBALS ---
chan deptQueue_C = [10] of { byte, mtype:customerType };
chan deptVIPQueue_C = [10] of { byte };
byte operatingRoomUniversalId = 0;
mtype:opRoomState opRoom[N_OPERATING_ROOM] = CLEAN;
byte preOPCustomerID = 0;
mtype:customerType preOPCustomerType;
bool isPreOPReady = false;
byte nWaitingCustomer_DeptC = 0;
byte nProcessingCustomer_DeptC = 0;  // FIXED: Track customers being treated

// --- PROCESS: CLOCK TICKING (THE HEARTBEAT) ---
// FIXED: Simplified synchronization using broadcast channel
active proctype ClockTicking() {
    chan subscribers[MAX_PROCESSES];
    byte nSubscribers = 0;
    mtype:messageType reqMsg;
    chan reqChan;
    byte i;
    
    do 
    :: {
        // 1. Process Registrations (non-blocking)
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

        // 2. Broadcast TICK to all subscribers
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

        // FIXED: Stop only when all customers are served
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
        :: isClosed -> break;  // FIXED: Stop generating when closed
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
                    atomic {
                        newCustomer.id = customerUniversalId;
                        customerUniversalId++;
                    }
                    if
                        :: 1 -> newCustomer.dept = A;
                        :: 2 -> newCustomer.dept = B;
                        :: 3 -> newCustomer.dept = C;
                    fi
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
                :: nempty(customerEntrance) -> customerEntrance ? processingCustomer;
                :: empty(customerEntrance) && isClosed -> break;  // FIXED: Process remaining then exit
                :: empty(customerEntrance) && !isClosed -> {
                    // Wait for customers
                    customerEntrance ? processingCustomer;
                }
            fi

            select (processingTime: 1 .. 5);
            timeRegistration ! SUB, myChan;

            do
                :: globalTick ? TICK -> {
                    processingTime--;
                    if
                        :: processingTime == 0 -> {
                            // FIXED: Unified admission control (removed per-dept closure flags)
                            if 
                                :: processingCustomer.dept == A && !isClosed -> {
                                    // FIXED: Account for parallel processing
                                    if
                                        :: globalTime <= TIME_LIMIT - (nWaitingCustomer_DeptA + 1) * avgParallelTreatmentTime_DeptA -> {
                                            customerHallway ! processingCustomer;
                                            nWaitingCustomer_DeptA++;
                                        }
                                        :: else -> skip;  // Reject customer
                                    fi
                                }
                                :: processingCustomer.dept == B -> {
                                    skip;  // Placeholder
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
        :: globalTick ? TICK -> {
            // 1. Accept new customers from GateKeeper
            do
                :: nempty(customerHallway) -> {
                    customerHallway ? walkCus[index].customer;
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
                            if
                                :: walkCus[i].customer.dept == A -> {
                                    if
                                        :: walkCus[i].customer.type == VIP -> {
                                            deptVIPQueue_A ! walkCus[i].customer.id;
                                        }
                                        :: walkCus[i].customer.type == INS -> {
                                            deptInsQueue_A ! walkCus[i].customer.id;
                                        }
                                        :: walkCus[i].customer.type == NORM -> {
                                            deptNormQueue_A ! walkCus[i].customer.id;
                                        }
                                    fi
                                }
                                :: walkCus[i].customer.dept == B -> {
                                    skip;  // Placeholder
                                }
                                :: walkCus[i].customer.dept == C -> {
                                    if
                                        :: walkCus[i].customer.type == VIP -> {
                                            deptVIPQueue_C ! walkCus[i].customer.id;
                                        }
                                        :: else -> {
                                            deptQueue_C ! walkCus[i].customer.id, walkCus[i].customer.type;
                                        }
                                    fi
                                }
                            fi

                            // Remove from array
                            for (j : i .. index-2) {
                                walkCus[j] = walkCus[j + 1];
                            }
                            index--;
                            i--;
                        }
                        :: else -> skip;
                    fi
                    i++;
                }
            od

            // FIXED: Exit when closed and no more customers walking
            if
                :: isClosed && index == 0 && empty(customerHallway) -> {
                    timeRegistration ! UNSUB, myChan;
                }
                :: else -> skip;
            fi

            myChan ! ACK;
            
            if
                :: isClosed && index == 0 && empty(customerHallway) -> break;
                :: else -> skip;
            fi
        }
    od
}

// --- PROCESS: DEPARTMENT A DOCTORS ---
active [3] proctype DoctorA() {
    chan myChan = [1] of { mtype:messageType };
    byte doctorId = _pid;
    byte patientId;
    mtype:customerType pType;
    byte treatTime;
    byte myMachineId = 255;  // 255 = no machine assigned
    bool hasPatient = false;

    do
    :: {
        // Exit condition: closed and no more work
        if
            :: isClosed && nWaitingCustomer_DeptA == 0 && 
               empty(deptVIPQueue_A) && empty(deptInsQueue_A) && 
               empty(deptNormQueue_A) -> break;
            :: else -> skip;
        fi

        // PHASE 1: Try to reserve a machine (non-blocking check)
        atomic {
            if
                // Try to get any available machine
                :: machinesAvailable > 0 -> {
                    byte i;
                    for (i : 0 .. N_MACHINE_A-1) {
                        if
                            :: !machineReserved[i] -> {
                                machineReserved[i] = true;
                                machineReservedBy[i] = doctorId;
                                myMachineId = i;
                                machinesAvailable--;
                                break;
                            }
                            :: else -> skip;
                        fi
                    }
                }
                :: else -> skip;  // No machines available, will wait
            fi
        }

        // PHASE 2: If we have a machine, get a patient with priority
        if
            :: myMachineId != 255 -> {
                atomic {
                    if
                        // Priority 1: VIP (always first)
                        :: nempty(deptVIPQueue_A) -> {
                            deptVIPQueue_A ? patientId;
                            pType = VIP;
                            nWaitingCustomer_DeptA--;
                            nProcessingCustomer_DeptA++;
                            hasPatient = true;
                        }
                        // Priority 2: Insured
                        :: empty(deptVIPQueue_A) && nempty(deptInsQueue_A) -> {
                            deptInsQueue_A ? patientId;
                            pType = INS;
                            nWaitingCustomer_DeptA--;
                            nProcessingCustomer_DeptA++;
                            hasPatient = true;
                        }
                        // Priority 3: Normal
                        :: empty(deptVIPQueue_A) && empty(deptInsQueue_A) && 
                           nempty(deptNormQueue_A) -> {
                            deptNormQueue_A ? patientId;
                            pType = NORM;
                            nWaitingCustomer_DeptA--;
                            nProcessingCustomer_DeptA++;
                            hasPatient = true;
                        }
                        // No patient available - release machine and try again
                        :: empty(deptVIPQueue_A) && empty(deptInsQueue_A) && 
                           empty(deptNormQueue_A) -> {
                            machineReserved[myMachineId] = false;
                            machineReservedBy[myMachineId] = 255;
                            machinesAvailable++;
                            myMachineId = 255;
                            hasPatient = false;
                        }
                    fi
                }
            }
            :: else -> {
                // No machine yet - check if we can interrupt for VIP
                atomic {
                    if
                        // If VIP is waiting and we have no machine, just wait
                        // (VIP will be served by whoever gets machine next)
                        :: nempty(deptVIPQueue_A) || nempty(deptInsQueue_A) || 
                           nempty(deptNormQueue_A) -> {
                            // Wait a bit before trying again (yield to other doctors)
                            hasPatient = false;
                        }
                        :: else -> hasPatient = false;
                    fi
                }
            }
        fi

        // PHASE 3: Treat patient if we have both machine and patient
        if
            :: hasPatient && myMachineId != 255 -> {
                select(treatTime: 10..20);
                timeRegistration ! SUB, myChan;
                
                do
                :: globalTick ? TICK -> {
                    treatTime--;
                    
                    // Check if we should yield to VIP
                    if
                        :: pType != VIP && treatTime > 2 && nempty(deptVIPQueue_A) -> {
                            // Yield to VIP: Return current patient to appropriate queue
                            if
                                :: pType == INS -> deptInsQueue_A ! patientId;
                                :: pType == NORM -> deptNormQueue_A ! patientId;
                            fi
                            nWaitingCustomer_DeptA++;
                            nProcessingCustomer_DeptA--;
                            
                            // Release machine
                            machineReserved[myMachineId] = false;
                            machineReservedBy[myMachineId] = 255;
                            machinesAvailable++;
                            myMachineId = 255;
                            
                            timeRegistration ! UNSUB, myChan;
                            myChan ! ACK;
                            break;
                        }
                        :: else -> skip;
                    fi
                    
                    if
                    :: treatTime == 0 -> {
                        // Treatment complete
                        machineReserved[myMachineId] = false;
                        machineReservedBy[myMachineId] = 255;
                        machinesAvailable++;
                        myMachineId = 255;
                        nProcessingCustomer_DeptA--;
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
            :: else -> skip;  // No work to do this cycle
        fi
    }
    od
}

// --- PROCESS: DEPARTMENT C PRE-OP ---
active proctype PreOPRoom() {
    chan myChan = [1] of { mtype:messageType };
    byte preOPTime;

    do
        :: {
            // FIXED: Exit when closed and no more customers
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

    do
        :: {
            // FIXED: Exit when closed and no more work
            if
                :: isClosed && nProcessingCustomer_DeptC == 0 && !isPreOPReady -> break;
                :: else -> skip;
            fi

            atomic {
                if
                    :: opRoom[opRoomId] == CLEAN && isPreOPReady -> {
                        currentCustomerId = preOPCustomerID;
                        currentCustomerType = preOPCustomerType;
                        isPreOPReady = false;
                        opRoom[opRoomId] = BUSY;
                    }
                    :: else -> skip;
                fi
            }

            // Only proceed if we got a patient
            if
                :: opRoom[opRoomId] == BUSY -> {
                    select (operatingTime: 20 .. 30);
                    timeRegistration ! SUB, myChan;
                    
                    do
                        :: globalTick ? TICK -> {
                            operatingTime--;
                            if
                                :: operatingTime == 0 -> { 
                                    opRoom[opRoomId] = DIRTY;
                                    nProcessingCustomer_DeptC--;
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
                :: else -> skip;
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
            // FIXED: Exit when closed and all rooms clean
            if
                :: isClosed && opRoom[0] != DIRTY && opRoom[1] != DIRTY && 
                   nProcessingCustomer_DeptC == 0 -> break;
                :: else -> skip;
            fi

            if
                :: opRoom[0] == DIRTY -> cleaningRoomId = 0;
                :: opRoom[1] == DIRTY -> cleaningRoomId = 1;
                :: else -> skip;  // No dirty rooms
            fi

            // Only proceed if we found a dirty room
            if
                :: opRoom[cleaningRoomId] == DIRTY -> {
                    select (cleaningTime: 5 .. 10);
                    timeRegistration ! SUB, myChan;
                    
                    do
                        :: globalTick ? TICK -> {
                            cleaningTime--;
                            if
                                :: cleaningTime == 0 -> {
                                    opRoom[cleaningRoomId] = CLEAN;
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
                :: else -> skip;
            fi
        }
    od
}