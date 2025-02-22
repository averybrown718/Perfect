//
//  NetNamedPipe.swift
//  PerfectLib
//
//  Created by Kyle Jessup on 7/5/15.
//	Copyright (C) 2015 PerfectlySoft, Inc.
//
//	This program is free software: you can redistribute it and/or modify
//	it under the terms of the GNU Affero General Public License as
//	published by the Free Software Foundation, either version 3 of the
//	License, or (at your option) any later version, as supplemented by the
//	Perfect Additional Terms.
//
//	This program is distributed in the hope that it will be useful,
//	but WITHOUT ANY WARRANTY; without even the implied warranty of
//	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//	GNU Affero General Public License, as supplemented by the
//	Perfect Additional Terms, for more details.
//
//	You should have received a copy of the GNU Affero General Public License
//	and the Perfect Additional Terms that immediately follow the terms and
//	conditions of the GNU Affero General Public License along with this
//	program. If not, see <http://www.perfect.org/AGPL_3_0_With_Perfect_Additional_Terms.txt>.
//


import Darwin

/// This sub-class of NetTCP handles networking over an AF_UNIX named pipe connection.
public class NetNamedPipe : NetTCP {
	
	/// Initialize the object using an existing file descriptor.
	public convenience init(fd: Int32) {
		self.init()
		self.fd.fd = fd
		self.fd.family = AF_UNIX
		self.fd.switchToNBIO()
	}
	
	/// Override socket initialization to handle the UNIX socket type.
	public override func initSocket() {
		fd.fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
		fd.family = AF_UNIX
		fd.switchToNBIO()
	}
	
	/// Bind the socket to the address path
	/// - parameter address: The path on the file system at which to create and bind the socket
	/// - throws: `PerfectError.NetworkError`
	public func bind(address: String) throws {
		
		initSocket()
		
		let utf8 = address.utf8
		let addrLen = sizeof(UInt8) + sizeof(sa_family_t) + utf8.count + 1
		let addrPtr = UnsafeMutablePointer<UInt8>.alloc(addrLen)
		
		defer { addrPtr.destroy() }
		
		var memLoc = 0
		
		addrPtr[memLoc++] = UInt8(addrLen)
		addrPtr[memLoc++] = UInt8(AF_UNIX)
		
		for char in utf8 {
			addrPtr[memLoc++] = char
		}
		
		addrPtr[memLoc] = 0
		
		let bRes = Darwin.bind(fd.fd, UnsafePointer<sockaddr>(addrPtr), socklen_t(addrLen))
		if bRes == -1 {
			throw PerfectError.NetworkError(errno, String.fromCString(strerror(errno))!)
		}
	}
	
	/// Connect to the indicated server socket
	/// - parameter address: The server socket file.
	/// - parameter timeoutSeconds: The number of seconds to wait for the connection to complete. A timeout of negative one indicates that there is no timeout.
	/// - parameter callBack: The closure which will be called when the connection completes. If the connection completes successfully then the current NetNamedPipe instance will be passed to the callback, otherwise, a nil object will be passed.
	/// - returns: `PerfectError.NetworkError`
	public func connect(address: String, timeoutSeconds: Double, callBack: (NetNamedPipe?) -> ()) throws {
		
		initSocket()
		
		let utf8 = address.utf8
		let addrLen = sizeof(UInt8) + sizeof(sa_family_t) + utf8.count + 1
		let addrPtr = UnsafeMutablePointer<UInt8>.alloc(addrLen)
		
		defer { addrPtr.destroy() }
		
		var memLoc = 0
		
		addrPtr[memLoc++] = UInt8(addrLen)
		addrPtr[memLoc++] = UInt8(AF_UNIX)
		
		for char in utf8 {
			addrPtr[memLoc++] = char
		}
		
		addrPtr[memLoc] = 0
		
		let cRes = Darwin.connect(fd.fd, UnsafePointer<sockaddr>(addrPtr), socklen_t(addrLen))
		if cRes != -1 {
			callBack(self)
		} else {
			guard errno == EINPROGRESS else {
				try ThrowNetworkError()
			}
			
			let event: LibEvent = LibEvent(base: LibEvent.eventBase, fd: fd.fd, what: EV_WRITE, userData: nil) {
				(fd:Int32, w:Int16, ud:AnyObject?) -> () in
				
				if (Int32(w) & EV_TIMEOUT) != 0 {
					callBack(nil)
				} else {
					callBack(self)
				}
			}
			event.add(timeoutSeconds)
		}
	}

	/// Send the existing opened file descriptor over the connection to the recipient
	/// - parameter fd: The file descriptor to send
	/// - parameter callBack: The callback to call when the send completes. The parameter passed will be `true` if the send completed without error.
	/// - throws: `PerfectError.NetworkError`
	public func sendFd(fd: Int32, callBack: (Bool) -> ()) throws {
		let length = sizeof(Darwin.cmsghdr) + sizeof(Int32)
		let msghdr = UnsafeMutablePointer<Darwin.msghdr>.alloc(1)
		let nothingPtr = UnsafeMutablePointer<iovec>.alloc(1)
		let nothing = UnsafeMutablePointer<CChar>.alloc(1)
		let buffer = UnsafeMutablePointer<CChar>.alloc(length)
		defer {
			msghdr.destroy()
			msghdr.dealloc(1)
			buffer.destroy()
			buffer.dealloc(length)
			nothingPtr.destroy()
			nothingPtr.dealloc(1)
			nothing.destroy()
			nothing.dealloc(1)
		}
		
		let cmsg = UnsafeMutablePointer<cmsghdr>(buffer)
		cmsg.memory.cmsg_len = socklen_t(length)
		cmsg.memory.cmsg_level = SOL_SOCKET
		cmsg.memory.cmsg_type = SCM_RIGHTS
		
		let asInts = UnsafeMutablePointer<Int32>(cmsg.advancedBy(1))
		asInts.memory = fd
		
		nothing.memory = 33
		
		nothingPtr.memory.iov_base = UnsafeMutablePointer<Void>(nothing)
		nothingPtr.memory.iov_len = 1
		
		msghdr.memory.msg_name = UnsafeMutablePointer<Void>(())
		msghdr.memory.msg_namelen = 0
		msghdr.memory.msg_flags = 0
		msghdr.memory.msg_iov = nothingPtr
		msghdr.memory.msg_iovlen = 1
		msghdr.memory.msg_control = UnsafeMutablePointer<Void>(buffer)
		msghdr.memory.msg_controllen = socklen_t(length)
		
		let res = Darwin.sendmsg(Int32(self.fd.fd), msghdr, 0)
		if res > 0 {
			callBack(true)
		} else if res == -1 && errno == EAGAIN {
			
			let event: LibEvent = LibEvent(base: LibEvent.eventBase, fd: self.fd.fd, what: EV_WRITE, userData: nil) {
				(fd:Int32, w:Int16, ud:AnyObject?) -> () in
				
				if (Int32(w) & EV_TIMEOUT) != 0 {
					callBack(false)
				} else {
					do {
						try self.sendFd(fd, callBack: callBack)
					} catch {
						callBack(false)
					}
				}
			}
			event.add()
			
		} else {
			try ThrowNetworkError()
		}
	}
	
	/// Receive an existing opened file descriptor from the sender
	/// - parameter callBack: The callback to call when the receive completes. The parameter passed will be the received file descriptor or invalidSocket.
	/// - throws: `PerfectError.NetworkError`
	public func receiveFd(callBack: (Int32) -> ()) throws {
		let length = sizeof(Darwin.cmsghdr) + sizeof(Int32)
		var msghdr = Darwin.msghdr()
		let nothingPtr = UnsafeMutablePointer<iovec>.alloc(1)
		let nothing = UnsafeMutablePointer<CChar>.alloc(1)
		let buffer = UnsafeMutablePointer<CChar>.alloc(length)
		defer {
			buffer.destroy()
			buffer.dealloc(length)
			nothingPtr.destroy()
			nothingPtr.dealloc(1)
			nothing.destroy()
			nothing.dealloc(1)
		}
		
		nothing.memory = 33
		
		nothingPtr.memory.iov_base = UnsafeMutablePointer<Void>(nothing)
		nothingPtr.memory.iov_len = 1
		
		msghdr.msg_iov = UnsafeMutablePointer<iovec>(nothingPtr)
		msghdr.msg_iovlen = 1
		msghdr.msg_control = UnsafeMutablePointer<Void>(buffer)
		msghdr.msg_controllen = socklen_t(length)
		
		let cmsg = UnsafeMutablePointer<cmsghdr>(buffer)
		cmsg.memory.cmsg_len = socklen_t(length)
		cmsg.memory.cmsg_level = SOL_SOCKET
		cmsg.memory.cmsg_type = SCM_RIGHTS
		
		let asInts = UnsafeMutablePointer<Int32>(cmsg.advancedBy(1))
		asInts.memory = -1
		
		let res = Darwin.recvmsg(Int32(self.fd.fd), &msghdr, 0)
		if res > 0 {
			let receivedInt = asInts.memory
			callBack(receivedInt)
		} else if res == -1 && errno == EAGAIN {
			
			let event: LibEvent = LibEvent(base: LibEvent.eventBase, fd: self.fd.fd, what: EV_READ, userData: nil) {
				(fd:Int32, w:Int16, ud:AnyObject?) -> () in
				
				if (Int32(w) & EV_TIMEOUT) != 0 {
					callBack(invalidSocket)
				} else {
					do {
						try self.receiveFd(callBack)
					} catch {
						callBack(invalidSocket)
					}
				}
			}
			event.add()
			
		} else {
			try ThrowNetworkError()
		}
		
	}
	
	/// Send the existing & opened `File`'s descriptor over the connection to the recipient
	/// - parameter file: The `File` whose descriptor to send
	/// - parameter callBack: The callback to call when the send completes. The parameter passed will be `true` if the send completed without error.
	/// - throws: `PerfectError.NetworkError`
	public func sendFile(file: File, callBack: (Bool) -> ()) throws {
		try self.sendFd(Int32(file.fd), callBack: callBack)
	}
	
	/// Send the existing & opened `NetTCP`'s descriptor over the connection to the recipient
	/// - parameter file: The `NetTCP` whose descriptor to send
	/// - parameter callBack: The callback to call when the send completes. The parameter passed will be `true` if the send completed without error.
	/// - throws: `PerfectError.NetworkError`
	public func sendFile(file: NetTCP, callBack: (Bool) -> ()) throws {
		try self.sendFd(file.fd.fd, callBack: callBack)
	}
	
	/// Receive an existing opened `File` descriptor from the sender
	/// - parameter callBack: The callback to call when the receive completes. The parameter passed will be the received `File` object or nil.
	/// - throws: `PerfectError.NetworkError`
	public func receiveFile(callBack: (File?) -> ()) throws {
		try self.receiveFd {
			(fd: Int32) -> () in
			
			if fd == invalidSocket {
				callBack(nil)
			} else {
				callBack(File(fd: fd, path: ""))
			}
		}
	}
	
	/// Receive an existing opened `NetTCP` descriptor from the sender
	/// - parameter callBack: The callback to call when the receive completes. The parameter passed will be the received `NetTCP` object or nil.
	/// - throws: `PerfectError.NetworkError`
	public func receiveNetTCP(callBack: (NetTCP?) -> ()) throws {
		try self.receiveFd {
			(fd: Int32) -> () in
			
			if fd == invalidSocket {
				callBack(nil)
			} else {
				callBack(NetTCP(fd: fd))
			}
		}
	}
	
	/// Receive an existing opened `NetNamedPipe` descriptor from the sender
	/// - parameter callBack: The callback to call when the receive completes. The parameter passed will be the received `NetNamedPipe` object or nil.
	/// - throws: `PerfectError.NetworkError`
	public func receiveNetNamedPipe(callBack: (NetNamedPipe?) -> ()) throws {
		try self.receiveFd {
			(fd: Int32) -> () in
			
			if fd == invalidSocket {
				callBack(nil)
			} else {
				callBack(NetNamedPipe(fd: fd))
			}
		}
	}
	
	override func makeFromFd(fd: Int32) -> NetTCP {
		return NetNamedPipe(fd: fd)
	}
}


