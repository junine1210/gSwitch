//
//  GPUManager.swift
//  gSwitch
//
//  Created by Cody Schrank on 4/14/18.
//  Copyright © 2018 CodySchrank. All rights reserved.
//

import Foundation
import IOKit

class GPUManager {
    static var _connect: io_connect_t = IO_OBJECT_NULL;
    var requestedMode: SwitcherMode?
    
    public func connect() throws {
        var kernResult: kern_return_t = 0
        var service: io_service_t = IO_OBJECT_NULL
        var iterator: io_iterator_t = 0
        
        kernResult = IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching(Constants.GRAPHICS_CONTROL), &iterator);
        
        if kernResult != KERN_SUCCESS {
            throw RuntimeError.CanNotConnect("IOServiceGetMatchingServices returned \(kernResult)")
        }
        
        service = IOIteratorNext(iterator);
        IOObjectRelease(iterator);
        
        if service == IO_OBJECT_NULL {
            throw RuntimeError.CanNotConnect("No matching drivers found.");
        }
        
        kernResult = IOServiceOpen(service, mach_task_self_, 0, &GPUManager._connect);
        if kernResult != KERN_SUCCESS {
            throw RuntimeError.CanNotConnect("IOServiceOpen returned \(kernResult)");
        }
        
        kernResult = IOConnectCallScalarMethod(GPUManager._connect, UInt32(DispatchSelectors.kOpen.rawValue), nil, 0, nil, nil);
        if kernResult != KERN_SUCCESS {
            throw RuntimeError.CanNotConnect("IOConnectCallScalarMethod returned \(kernResult)")
        }
        
        print("Successfully connected")
    }
    
    public func close() -> Bool {
        var kernResult: kern_return_t = 0
        if GPUManager._connect == IO_OBJECT_NULL {
            return true;
        }
        
        kernResult = IOConnectCallScalarMethod(GPUManager._connect, UInt32(DispatchSelectors.kClose.rawValue), nil, 0, nil, nil);
        if kernResult != KERN_SUCCESS {
            print("IOConnectCallScalarMethod returned ", kernResult)
            return false
        }
        
        kernResult = IOServiceClose(GPUManager._connect);
        if kernResult != KERN_SUCCESS {
            print("IOServiceClose returned", kernResult)
            return false
        }
        
        GPUManager._connect = IO_OBJECT_NULL
        print("Driver Connection Closed")
        
        return true
    }
    
    public func GPUMode(mode: SwitcherMode) -> Bool {
        let connect = GPUManager._connect
        
        requestedMode = mode
        
        var status = false
        
        if connect == IO_OBJECT_NULL {
            return status
        }
        
        switch mode {
        case .ForceIntergrated:
            
            let integrated = isUsingIntegratedGPU()
            print("Requesting integrated, are we integrated?  \(integrated)")
            
            if (mode == .ForceIntergrated && !integrated) {
                status = SwitchGPU(connect: connect)
            }
            
        case .ForceDiscrete:
            let discrete = isUsingDedicatedGPU()
            print("Requesting discrete, are we discrete?  \(discrete)")
            
            if (mode == .ForceDiscrete && !discrete) {
                status = SwitchGPU(connect: connect)
            }
        case .SetDynamic:
            // Set switch policy back, make the MBP think it's an auto switching one once again
            _ = setFeatureInfo(connect: connect, feature: Features.Policy, enabled: true)
            _ = setSwitchPolicy(connect: connect)
            
            status = setDynamicSwitching(connect: connect, enabled: true)
        }
        
        return status
    }
    
    public func isUsingIntegratedGPU() -> Bool {
        if GPUManager._connect == IO_OBJECT_NULL {
            return false  //throw
        }
        
        return getGPUState(connect: GPUManager._connect, input: GPUState.GraphicsCard) != 0
    }
    
    public func isUsingDynamicSwitching() -> Bool {
        if GPUManager._connect == IO_OBJECT_NULL {
            return false //throw
        }
        
        return getGPUState(connect: GPUManager._connect, input: GPUState.GpuSelect) != 0
    }
    
    public func isUsingDedicatedGPU() -> Bool {
        return !isUsingIntegratedGPU()
    }
    
    /**
         This doesn't switch the gpu for me just sets it to integrated..
         But I'm keeping it SwitchGPU for now
     **/
    private func SwitchGPU(connect: io_connect_t) -> Bool {
        let _ = setDynamicSwitching(connect: connect, enabled: false)
        
        // Hold up a sec!
        sleep(1);
        
        return setGPUState(connect: connect, state: GPUState.ForceSwitch, arg: 0)
    }
    
    private func setGPUState(connect: io_connect_t ,state: GPUState, arg: UInt64) -> Bool {
        var kernResult: kern_return_t = 0
        
        let scalar: [UInt64] = [ 1, UInt64(state.rawValue), arg ];
        
        kernResult = IOConnectCallScalarMethod(
            // an io_connect_t returned from IOServiceOpen().
            connect,
            
            // selector of the function to be called via the user client.
            UInt32(DispatchSelectors.kSetMuxState.rawValue),
            
            // array of scalar (64-bit) input values.
            scalar,
            
            // the number of scalar input values.
            3,
            
            // array of scalar (64-bit) output values.
            nil,
            
            // pointer to the number of scalar output values.
            nil
        );

        if kernResult == KERN_SUCCESS {
            print("Successfully set state")
        } else {
            print("ERROR: Set state returned", kernResult)
        }
            
        return kernResult == KERN_SUCCESS
    }
    
    private func getGPUState(connect: io_connect_t, input: GPUState) -> UInt64 {
        var kernResult: kern_return_t = 0
        let scalar: [UInt64] = [ 1, UInt64(input.rawValue) ];
        var output: UInt64 = 0
        var outputCount: UInt32 = 1
        
        kernResult = IOConnectCallScalarMethod(
            // an io_connect_t returned from IOServiceOpen().
            connect,
            
            // selector of the function to be called via the user client.
            UInt32(DispatchSelectors.kGetMuxState.rawValue),
            
            // array of scalar (64-bit) input values.
            scalar,
            
            // the number of scalar input values.
            2,
            
            // array of scalar (64-bit) output values.
            &output,
            
            // pointer to the number of scalar output values.
            &outputCount
        );
        
        if kernResult == KERN_SUCCESS {
            print("Successfully got state, count \(outputCount), value \(output)")
        } else {
            print("ERROR: Get state returned", kernResult)
        }
        
        return output
    }
    
    private func setFeatureInfo(connect: io_connect_t, feature: Features, enabled: Bool) -> Bool {
        return setGPUState(
            connect: connect,
            state: enabled ? GPUState.EnableFeatureORFeatureInfo2 : GPUState.DisableFeatureORFeatureInfo,
            arg: 1 << feature.rawValue)
    }
    
    private func setSwitchPolicy(connect: io_connect_t) -> Bool {
        /** If old style switching needs to be enabled arg needs to be a 2 */
        return setGPUState(connect: connect, state: GPUState.SwitchPolicy, arg: 0)
    }
    
    private func setDynamicSwitching(connect: io_connect_t, enabled: Bool) -> Bool {
        return setGPUState(connect: connect, state: GPUState.GpuSelect, arg: enabled ? 1 : 0);
    }
    
    private func getGpuNames() -> [String] {
        let ioProvider = IOServiceMatching(Constants.IO_PCI_DEVICE)
        var iterator: io_iterator_t = 0
        
        var gpus = [String]()
        
        if(IOServiceGetMatchingServices(kIOMasterPortDefault, ioProvider, &iterator) == kIOReturnSuccess) {
            var device: io_registry_entry_t = 0
            
            repeat {
                device = IOIteratorNext(iterator)
                var serviceDictionary: Unmanaged<CFMutableDictionary>?;
                
                if (IORegistryEntryCreateCFProperties(device, &serviceDictionary, kCFAllocatorDefault, 0) != kIOReturnSuccess) {
                    // Couldn't get the properties
                    IOObjectRelease(device)
                    continue;
                }
                
                if let props = serviceDictionary {
                    let dict = props.takeRetainedValue() as NSDictionary
                    
                    if let d = dict.object(forKey: Constants.IO_NAME_KEY) as? String {
                        if d == Constants.DISPLAY_KEY {
                            let model = dict.object(forKey: Constants.MODEL_KEY) as! Data
                            gpus.append(String(data: model, encoding: .ascii)!)
                        }
                    }
                }
            } while (device != 0)
        }
        
        return gpus
    }
    
}

